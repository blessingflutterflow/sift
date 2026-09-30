/**
 * Paystack money flow — webhook (source of truth), card vault, driver
 * subaccounts, refunds. The secret key lives in Functions Secrets; clients
 * never see it and never compute money.
 *
 * Trust model: callables *initiate* (checkout links, charges), but a payment
 * is only ever treated as real when the signed webhook confirms it. The
 * webhook is idempotent — Paystack retries, and we must not double-credit.
 */
const crypto = require("crypto");
const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const paystack = require("./paystack");
const { readPricing, splitFare } = require("./pricing");

const REGION = "europe-west1";
const SECRET = paystack.PAYSTACK_SECRET_KEY;
const db = () => admin.firestore();

// ---------------------------------------------------------------------------
// Webhook — the authoritative money event sink.
// ---------------------------------------------------------------------------
exports.paystackWebhook = onRequest(
  { region: REGION, secrets: [SECRET], cors: false },
  async (req, res) => {
    // 1. Verify the signature against the RAW body (not the parsed JSON).
    const signature = req.headers["x-paystack-signature"];
    const expected = crypto
      .createHmac("sha512", SECRET.value())
      .update(req.rawBody)
      .digest("hex");
    if (!signature || signature !== expected) {
      logger.warn("paystackWebhook bad signature");
      res.status(401).send("invalid signature");
      return;
    }

    const event = req.body;
    const type = event?.event;
    const data = event?.data || {};
    const reference = data.reference;

    // 2. Idempotency: claim this (event,reference) once. Retries no-op.
    if (reference) {
      const claim = db().collection("webhook_events").doc(`${type}:${reference}`);
      const fresh = await db().runTransaction(async (txn) => {
        const s = await txn.get(claim);
        if (s.exists) return false;
        txn.set(claim, {
          type,
          reference,
          receivedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (!fresh) {
        res.status(200).send("duplicate");
        return;
      }
    }

    // 3. Always ack fast; processing failures are logged, not retried forever.
    try {
      if (type === "charge.success") await handleChargeSuccess(data);
      else if (type === "refund.processed" || type === "refund.failed") {
        await handleRefund(type, data);
      }
    } catch (e) {
      logger.error("paystackWebhook processing failed", { type, reference, e });
    }
    res.status(200).send("ok");
  }
);

async function handleChargeSuccess(data) {
  const purpose = data.metadata?.purpose;
  if (purpose === "card_vault") return vaultCard(data);
  if (purpose === "trip") return settleTripCharge(data);
  if (purpose === "debt") return settleDebtPayment(data);
  if (purpose === "driver_debt") return settleDriverDebt(data);
  if (purpose === "wallet_topup") return settleWalletTopup(data);
  if (purpose === "parcel") return settleParcelCharge(data);
  logger.info("charge.success ignored (no/unknown purpose)", {
    reference: data.reference,
    purpose,
  });
}

/** Driver paid their cash-commission debt: credit the ledger. */
async function settleDriverDebt(data) {
  const uid = data.metadata?.uid;
  if (!uid) return;
  const amount = paystack.toZar(data.amount);
  const ledgerRef = db().collection("ledgers").doc(uid);

  await db().runTransaction(async (txn) => {
    txn.set(
      ledgerRef,
      {
        balance: admin.firestore.FieldValue.increment(-amount),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    txn.set(ledgerRef.collection("entries").doc(), {
      type: "debt_payment",
      reference: data.reference,
      balanceDelta: -amount,
      amount,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    txn.set(db().collection("transactions").doc(data.reference), {
      reference: data.reference,
      driverId: uid,
      amount,
      method: "card",
      type: "driver_debt_payment",
      status: "success",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

/** Rider topped up their wallet: credit the balance + record the entry. */
async function settleWalletTopup(data) {
  const uid = data.metadata?.uid;
  if (!uid) return;
  const amount = paystack.toZar(data.amount);
  const walletRef = db().collection("wallets").doc(uid);

  await db().runTransaction(async (txn) => {
    txn.set(
      walletRef,
      {
        balance: admin.firestore.FieldValue.increment(amount),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    txn.set(walletRef.collection("entries").doc(), {
      type: "topup",
      reference: data.reference,
      amount,
      balanceDelta: amount,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    txn.set(db().collection("transactions").doc(data.reference), {
      reference: data.reference,
      riderId: uid,
      amount,
      method: "card",
      type: "wallet_topup",
      status: "success",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

/** Store the reusable card authorization on the rider's profile. */
async function vaultCard(data) {
  const uid = data.metadata?.uid;
  const auth = data.authorization;
  if (!uid || !auth?.authorization_code || !auth.reusable) return;
  const methods = db().collection("users").doc(uid).collection("payment_methods");
  // De-dupe by signature so re-adding the same card doesn't pile up.
  const existing = await methods
    .where("signature", "==", auth.signature)
    .limit(1)
    .get();
  const ref = existing.empty ? methods.doc() : existing.docs[0].ref;
  await ref.set(
    {
      authorizationCode: auth.authorization_code,
      last4: auth.last4,
      brand: auth.card_type || auth.brand,
      bank: auth.bank,
      expMonth: auth.exp_month,
      expYear: auth.exp_year,
      signature: auth.signature,
      email: data.customer?.email || null,
      isDefault: existing.empty,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  // Auto-refund the R1 vault probe.
  try {
    await paystack.refund({ reference: data.reference });
  } catch (e) {
    logger.warn("vault probe refund failed (non-fatal)", e?.message);
  }
}

/** Confirm a trip's card charge: mark paid, record txn + driver earning. */
async function settleTripCharge(data) {
  const rideId = data.metadata?.rideId;
  if (!rideId) return;
  const cfg = await readPricing();
  const rideRef = db().collection("rides").doc(rideId);

  await db().runTransaction(async (txn) => {
    const s = await txn.get(rideRef);
    const r = s.data();
    if (!r) return;
    const finalFare = paystack.toZar(data.amount);
    const { commission, driverEarning } = splitFare(finalFare, cfg);

    txn.update(rideRef, { paymentStatus: "paid", paidAt: admin.firestore.FieldValue.serverTimestamp() });

    txn.set(db().collection("transactions").doc(data.reference), {
      reference: data.reference,
      rideId,
      riderId: r.riderId,
      driverId: r.driverId || null,
      amount: finalFare,
      commission,
      driverEarning,
      method: "card",
      channel: data.channel || "card",
      status: "success",
      subaccountSettled: !!data.subaccount,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Card earnings settle to the driver's bank via the Paystack split, so
    // they don't change the cash-debt balance — recorded for the dashboard.
    if (r.driverId) {
      const entry = db()
        .collection("ledgers")
        .doc(r.driverId)
        .collection("entries")
        .doc();
      txn.set(entry, {
        type: "trip_earning_card",
        rideId,
        method: "card",
        finalFare,
        commission,
        driverEarning,
        balanceDelta: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });
}

/** Confirm a parcel's card charge: mark paid, record txn + driver earning. */
async function settleParcelCharge(data) {
  const parcelId = data.metadata?.parcelId;
  if (!parcelId) return;
  const cfg = await readPricing();
  const ref = db().collection("parcels").doc(parcelId);

  await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r) return;
    const finalFare = paystack.toZar(data.amount);
    const { commission, driverEarning } = splitFare(finalFare, cfg);

    txn.update(ref, {
      paymentStatus: "paid",
      paidAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    txn.set(db().collection("transactions").doc(data.reference), {
      reference: data.reference,
      parcelId,
      riderId: r.senderId,
      driverId: r.driverId || null,
      amount: finalFare,
      commission,
      driverEarning,
      method: "card",
      channel: data.channel || "card",
      type: "parcel",
      status: "success",
      subaccountSettled: !!data.subaccount,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (r.driverId) {
      txn.set(
        db().collection("ledgers").doc(r.driverId).collection("entries").doc(),
        {
          type: "parcel_earning_card",
          parcelId,
          method: "card",
          finalFare,
          commission,
          driverEarning,
          balanceDelta: 0,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }
      );
    }
  });
}

/** Rider clears an outstanding `payment_due` debt via fresh checkout. */
async function settleDebtPayment(data) {
  const rideId = data.metadata?.rideId;
  if (!rideId) return;
  const rideRef = db().collection("rides").doc(rideId);
  const s = await rideRef.get();
  const r = s.data() || {};
  await rideRef
    .update({ paymentStatus: "paid", paidAt: admin.firestore.FieldValue.serverTimestamp() })
    .catch(() => {});
  await db().collection("transactions").doc(data.reference).set({
    reference: data.reference,
    rideId,
    riderId: r.riderId || data.metadata?.uid || null,
    driverId: r.driverId || null,
    amount: paystack.toZar(data.amount),
    method: "card",
    channel: data.channel || "card",
    type: "debt_settlement",
    status: "success",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

async function handleRefund(type, data) {
  const reference = data.transaction_reference || data.reference;
  if (!reference) return;
  await db()
    .collection("transactions")
    .doc(reference)
    .set(
      {
        refundStatus: type === "refund.processed" ? "refunded" : "refund_failed",
        refundedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    )
    .catch(() => {});
}

// ---------------------------------------------------------------------------
// Card vault — rider adds a reusable card.
// ---------------------------------------------------------------------------
exports.initCardSetup = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const email = req.data?.email;
    if (!email) throw new HttpsError("invalid-argument", "email required.");

    const reference = `vault_${uid}_${Date.now()}`;
    try {
      const data = await paystack.initializeTransaction({
        email,
        amountZar: 1, // R1 probe, auto-refunded on success
        reference,
        channels: ["card"],
        metadata: { purpose: "card_vault", uid },
      });
      return {
        authorizationUrl: data.authorization_url,
        accessCode: data.access_code,
        reference,
      };
    } catch (e) {
      logger.error("initCardSetup failed", e?.message);
      throw new HttpsError("internal", "Could not start card setup.");
    }
  }
);

/**
 * Rider tops up their Sift wallet. Paystack checkout (purpose 'wallet_topup');
 * the webhook credits the wallet balance on success.
 */
exports.initWalletTopup = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const amount = Number(req.data?.amount);
    if (!amount || amount < 20) {
      throw new HttpsError("invalid-argument", "Minimum top-up is R20.");
    }
    if (amount > 5000) {
      throw new HttpsError("invalid-argument", "Maximum top-up is R5000.");
    }
    const email =
      req.data?.email ||
      (await db().collection("users").doc(uid).get()).data()?.email ||
      `${uid}@rider.sift.app`;

    const reference = `wallet_${uid}_${Date.now()}`;
    try {
      const data = await paystack.initializeTransaction({
        email,
        amountZar: amount,
        reference,
        metadata: { purpose: "wallet_topup", uid },
      });
      return { authorizationUrl: data.authorization_url, reference };
    } catch (e) {
      logger.error("initWalletTopup failed", e?.message);
      throw new HttpsError("internal", "Could not start the top-up.");
    }
  }
);

/**
 * Rider settles an outstanding ride (`paymentStatus: 'due'`) with a fresh
 * checkout. The webhook (purpose 'debt') flips the ride to paid.
 */
exports.initDebtPayment = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const rideId = req.data?.rideId;
    if (!rideId) throw new HttpsError("invalid-argument", "rideId required.");

    const s = await db().collection("rides").doc(rideId).get();
    const r = s.data();
    if (!r || r.riderId !== uid) {
      throw new HttpsError("permission-denied", "Not your ride.");
    }
    if (r.paymentStatus !== "due") {
      throw new HttpsError("failed-precondition", "Nothing owed on this ride.");
    }
    const amount = r.finalFare || r.quotedFare || r.fare;
    if (!amount || amount <= 0) {
      throw new HttpsError("failed-precondition", "No amount to charge.");
    }
    const email =
      req.data?.email ||
      (await db().collection("users").doc(uid).get()).data()?.email ||
      `${uid}@rider.sift.app`;

    const reference = `debt_${rideId}_${Date.now()}`;
    try {
      const data = await paystack.initializeTransaction({
        email,
        amountZar: amount,
        reference,
        metadata: { purpose: "debt", rideId, uid },
      });
      return { authorizationUrl: data.authorization_url, reference };
    } catch (e) {
      logger.error("initDebtPayment failed", e?.message);
      throw new HttpsError("internal", "Could not start the payment.");
    }
  }
);

/**
 * Driver settles their cash-commission debt (ledger balance) via checkout.
 * The webhook (purpose 'driver_debt') credits the ledger.
 */
exports.initDriverDebtPayment = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

    const ledger = await db().collection("ledgers").doc(uid).get();
    const balance = ledger.data()?.balance || 0;
    if (balance < 1) {
      throw new HttpsError("failed-precondition", "Nothing owed right now.");
    }
    const email =
      req.data?.email ||
      (await db().collection("users").doc(uid).get()).data()?.email ||
      `${uid}@driver.sift.app`;

    const reference = `drvdebt_${uid}_${Date.now()}`;
    try {
      const data = await paystack.initializeTransaction({
        email,
        amountZar: balance,
        reference,
        metadata: { purpose: "driver_debt", uid },
      });
      return { authorizationUrl: data.authorization_url, reference, amount: balance };
    } catch (e) {
      logger.error("initDriverDebtPayment failed", e?.message);
      throw new HttpsError("internal", "Could not start the payment.");
    }
  }
);

// ---------------------------------------------------------------------------
// Driver payout — bank lookup, account resolve, subaccount on approval.
// ---------------------------------------------------------------------------

/** Create the driver's Paystack subaccount from verified payout details. */
async function createSubaccountFor(uid, payout) {
  const cfg = await readPricing();
  const u = await db().collection("users").doc(uid).get();
  const businessName = u.data()?.name || `Sift Driver ${uid.slice(0, 6)}`;
  const created = await paystack.createSubaccount({
    businessName,
    bankCode: payout.bankCode,
    accountNumber: payout.accountNumber,
    percentageCharge: Math.round(cfg.commissionPct * 100),
  });
  return created.subaccount_code;
}

/**
 * Driver saves payout (bank) details — server-resolved so the stored account
 * name is verified, written via Admin SDK (the application doc is otherwise
 * locked once it leaves 'pending'). If the driver is already approved, the
 * subaccount is created on the spot.
 */
exports.savePayoutDetails = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const { accountNumber, bankCode, bankName } = req.data || {};
    if (!accountNumber || !bankCode) {
      throw new HttpsError(
        "invalid-argument",
        "accountNumber and bankCode required."
      );
    }

    // Paystack account-name resolution only supports NGN/USD/GHS/KES — NOT
    // South Africa (ZAR). So resolution is best-effort: if it fails (as it
    // always will for ZA), we still save the details + create the subaccount
    // from the bank code + account number (which Paystack DOES support for ZA).
    let accountName = "";
    try {
      const resolved = await paystack.resolveAccount({ accountNumber, bankCode });
      accountName = resolved.account_name || "";
    } catch (e) {
      logger.info("resolveAccount unavailable (expected for ZA/ZAR)", {
        msg: e?.message,
      });
    }

    const appRef = db().collection("applications").doc(uid);
    const appSnap = await appRef.get();
    const payout = {
      bankCode,
      bankName: bankName || "",
      accountNumber,
      accountName: accountName || "",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await appRef.set({ payout }, { merge: true });

    // Already-approved driver adding bank details later → subaccount now.
    let subaccountCode = appSnap.data()?.subaccountCode || null;
    if (!subaccountCode && appSnap.data()?.status === "approved") {
      try {
        subaccountCode = await createSubaccountFor(uid, payout);
        await appRef.set(
          {
            subaccountCode,
            subaccountCreatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      } catch (e) {
        logger.error("subaccount create on save failed", { uid, msg: e?.message });
      }
    }
    return { accountName: accountName || null, subaccountCode };
  }
);
exports.listBanks = onCall({ region: REGION, secrets: [SECRET] }, async (req) => {
  if (!req.auth?.uid) throw new HttpsError("unauthenticated", "Sign in required.");
  try {
    const banks = await paystack.listBanks();
    return (banks || []).map((b) => ({ name: b.name, code: b.code }));
  } catch (e) {
    logger.error("listBanks failed", e?.message);
    throw new HttpsError("internal", "Could not load banks.");
  }
});

exports.resolveBankAccount = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    if (!req.auth?.uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const { accountNumber, bankCode } = req.data || {};
    if (!accountNumber || !bankCode) {
      throw new HttpsError("invalid-argument", "accountNumber and bankCode required.");
    }
    try {
      const data = await paystack.resolveAccount({ accountNumber, bankCode });
      return { accountName: data.account_name };
    } catch (e) {
      throw new HttpsError("not-found", "Could not verify that account.");
    }
  }
);

/**
 * When an application flips to approved and has payout details but no
 * subaccount yet, create the Paystack subaccount that future card splits pay
 * out to. Percentage_charge is the PLATFORM commission %.
 */
exports.onApplicationApproved = onDocumentUpdated(
  { region: REGION, document: "applications/{uid}", secrets: [SECRET] },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};
    const uid = event.params.uid;

    const becameApproved =
      before.status !== "approved" && after.status === "approved";
    if (!becameApproved) return;
    if (after.subaccountCode) return; // already has one
    const payout = after.payout || {};
    if (!payout.bankCode || !payout.accountNumber) {
      logger.warn("approved driver missing payout details", { uid });
      return;
    }

    try {
      const code = await createSubaccountFor(uid, payout);
      await event.data.after.ref.set(
        {
          subaccountCode: code,
          subaccountCreatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      logger.info("subaccount created", { uid, code });
    } catch (e) {
      logger.error("createSubaccount failed", { uid, msg: e?.message });
    }
  }
);

// ---------------------------------------------------------------------------
// Refund — admin-only.
// ---------------------------------------------------------------------------
exports.refundTransaction = onCall(
  { region: REGION, secrets: [SECRET] },
  async (req) => {
    if (req.auth?.token?.admin !== true) {
      throw new HttpsError("permission-denied", "Admin only.");
    }
    const { reference, amountZar } = req.data || {};
    if (!reference) throw new HttpsError("invalid-argument", "reference required.");
    try {
      await paystack.refund({ reference, amountZar });
      return { ok: true };
    } catch (e) {
      throw new HttpsError("internal", e?.message || "Refund failed.");
    }
  }
);
