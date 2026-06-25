/**
 * Server-orchestrated sequential ride dispatch.
 *
 *  onRideRequested (Firestore trigger) — ranks nearby online drivers, offers to
 *      the closest, and enqueues a Cloud Task deadline.
 *  rideDispatchTick (Cloud Task)       — fires at the offer deadline; if still
 *      unaccepted, advances to the next driver (or expires).
 *  acceptRide / declineRide / cancelRide (callables) — driver/rider actions,
 *      all guarded by transactions so nothing can double-book.
 *  expireStaleRides (scheduled)        — backstop sweeper for orphans.
 *
 * Clients never orchestrate: the rider creates a request and listens; the
 * driver sees rides offered to them and accepts/declines.
 */
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onTaskDispatched } = require("firebase-functions/v2/tasks");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFunctions } = require("firebase-admin/functions");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const {
  readPricing,
  computeFare,
  computeWaitFee,
  splitFare,
  readZones,
  surgeForPoint,
} = require("./pricing");
const paystack = require("./paystack");

const REGION = "europe-west1";
const OFFER_SECONDS = 15;
const MAX_CANDIDATES = 6;
const MAX_RADIUS_KM = 20;
const ACTIVE = ["accepted", "arriving", "arrived", "in_progress"];

const db = () => admin.firestore();
const ridesRef = () => db().collection("rides");

function haversineKm(a, b) {
  const R = 6371;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const x =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

/** Ranked uids of online, non-busy drivers within range of the pickup. */
async function rankCandidates(pickup) {
  const [online, active] = await Promise.all([
    db().collection("driver_locations").where("online", "==", true).get(),
    ridesRef().where("status", "in", ACTIVE).get(),
  ]);
  const busy = new Set(
    active.docs.map((d) => d.data().driverId).filter(Boolean)
  );

  const cands = [];
  online.forEach((doc) => {
    const x = doc.data();
    if (busy.has(doc.id)) return;
    if (typeof x.lat !== "number" || typeof x.lng !== "number") return;
    const dist = haversineKm(pickup, { lat: x.lat, lng: x.lng });
    if (dist <= MAX_RADIUS_KM) {
      cands.push({ uid: doc.id, dist, lat: x.lat, lng: x.lng });
    }
  });
  cands.sort((a, b) => a.dist - b.dist);
  return cands.slice(0, MAX_CANDIDATES);
}

function tickQueue() {
  return getFunctions().taskQueue(
    `locations/${REGION}/functions/rideDispatchTick`
  );
}

async function enqueueTick(rideId, offerSeq) {
  await tickQueue().enqueue(
    { rideId, offerSeq },
    { scheduleDelaySeconds: OFFER_SECONDS + 2 }
  );
}

/**
 * Move the offer to the next candidate (transactionally). If the list is
 * exhausted, mark the ride expired. Returns { offerSeq } when an offer was made.
 */
async function offerNext(rideId) {
  const ref = ridesRef().doc(rideId);
  return db().runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    const r = snap.data();
    if (!r || r.status !== "requested") return { done: true };

    const cands = r.candidateIds || [];
    const idx = (r.candidateIndex ?? -1) + 1;
    const seq = (r.offerSeq ?? 0) + 1;

    if (idx >= cands.length) {
      txn.update(ref, {
        status: "expired",
        offeredTo: null,
        offerExpiresAt: null,
        offerSeq: seq,
      });
      return { done: true, expired: true };
    }

    const expires = admin.firestore.Timestamp.fromMillis(
      Date.now() + OFFER_SECONDS * 1000
    );
    txn.update(ref, {
      candidateIndex: idx,
      offeredTo: cands[idx],
      offerExpiresAt: expires,
      offerSeq: seq,
    });
    return { offerSeq: seq };
  });
}

/**
 * Stamp the authoritative fare/rider info, rank drivers, and make the first
 * offer. Shared by the create trigger (immediate rides) and the scheduler
 * (scheduled rides that have come due).
 */
async function beginDispatch(rideRef, ride) {
  const rideId = rideRef.id;

  // Stamp authoritative rider display info + server-computed fare. The
  // client's submitted `fare` is treated as a preview only; the number that
  // can ever be charged is recomputed here from config + trip distance.
  try {
    const [u, cfg, zones] = await Promise.all([
      db().collection("users").doc(ride.riderId).get(),
      readPricing(),
      readZones(),
    ]);
    const ud = u.data() || {};

    // Blocked riders can't dispatch — kill the request before any offers.
    if (ud.blocked === true) {
      await rideRef.update({ status: "expired", expiredReason: "rider_blocked" });
      return;
    }
    // Surge from the pickup's zone (or the city-wide default) folds into fare.
    const surge = surgeForPoint(ride.pickupLat, ride.pickupLng, zones, cfg);
    const quotedFare = computeFare(ride.distanceKm, ride.tierId, cfg, surge);
    await rideRef.update({
      riderName: ud.name || "Rider",
      riderPhone: ud.phone || "",
      quotedFare,
      fare: quotedFare,
      surgeMultiplier: surge,
      commissionPct: cfg.commissionPct,
      paymentMethod: ride.paymentMethod || "cash",
      paymentStatus: "unpaid",
    });
  } catch (e) {
    logger.warn("rider profile/fare stamp failed", e);
  }

  const candidates = await rankCandidates({
    lat: ride.pickupLat,
    lng: ride.pickupLng,
  });

  if (candidates.length === 0) {
    await rideRef.update({
      status: "expired",
      candidateIds: [],
      candidateIndex: -1,
    });
    return;
  }

  await rideRef.update({
    candidateIds: candidates.map((c) => c.uid),
    // Snapshot positions so the rider can show nearby cars (no driver PII).
    candidatePositions: candidates.map((c) => ({ lat: c.lat, lng: c.lng })),
    candidateIndex: -1,
    offerSeq: 0,
    // When dispatch actually began — the stale-ride sweeper keys off this so a
    // scheduled ride (old createdAt) isn't expired the instant it dispatches.
    dispatchedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const res = await offerNext(rideId);
  if (res.offerSeq) await enqueueTick(rideId, res.offerSeq);
}

exports.onRideRequested = onDocumentCreated(
  { region: REGION, document: "rides/{rideId}" },
  async (event) => {
    const snap = event.data;
    const ride = snap.data();
    // Scheduled rides are created with status 'scheduled' and dispatched later
    // by dispatchScheduledRides — only immediate ('requested') rides go now.
    if (!ride || ride.status !== "requested") return;
    await beginDispatch(snap.ref, ride);
  }
);

exports.rideDispatchTick = onTaskDispatched(
  { region: REGION, retryConfig: { maxAttempts: 3 }, rateLimits: { maxConcurrentDispatches: 50 } },
  async (req) => {
    const { rideId, offerSeq } = req.data || {};
    if (!rideId) return;
    const snap = await ridesRef().doc(rideId).get();
    const r = snap.data();
    if (!r || r.status !== "requested") return; // accepted/cancelled/expired
    if ((r.offerSeq ?? 0) !== offerSeq) return; // superseded (declined early)

    const res = await offerNext(rideId);
    if (res.offerSeq) await enqueueTick(rideId, res.offerSeq);
  }
);

exports.acceptRide = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const rideId = req.data?.rideId;
  if (!rideId) throw new HttpsError("invalid-argument", "rideId required.");

  const [u, a] = await Promise.all([
    db().collection("users").doc(uid).get(),
    db().collection("applications").doc(uid).get(),
  ]);
  if (u.data()?.blocked === true) {
    throw new HttpsError("permission-denied", "Your account is blocked.");
  }
  const ud = u.data() || {};
  const name = ud.name || "Driver";
  const phone = ud.phone || "";
  const v = a.data()?.vehicle || {};
  const vehicle =
    [v.color, v.make, v.model].filter(Boolean).join(" ") || "Vehicle";
  // Driver's KYC profile photo + aggregate rating, surfaced on the rider's
  // assigned-driver card. New drivers (no ratings yet) get a null rating.
  const photo = a.data()?.documents?.photo || null;
  const ratingCount = ud.ratingCount || 0;
  const rating = ratingCount > 0 ? ud.ratingAvg || null : null;

  const ref = ridesRef().doc(rideId);
  const ok = await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r || r.status !== "requested") return false;
    if (r.offeredTo !== uid) return false;
    if (r.offerExpiresAt && r.offerExpiresAt.toMillis() < Date.now()) return false;
    txn.update(ref, {
      status: "accepted",
      driverId: uid,
      driverName: name,
      driverPhone: phone,
      driverVehicle: vehicle,
      driverPhoto: photo,
      driverRating: rating,
      driverRatingCount: ratingCount,
      offeredTo: null,
      acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!ok) {
    throw new HttpsError("failed-precondition", "This ride is no longer available.");
  }
  return { ok: true };
});

exports.declineRide = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const rideId = req.data?.rideId;
  if (!rideId) throw new HttpsError("invalid-argument", "rideId required.");

  const snap = await ridesRef().doc(rideId).get();
  const r = snap.data();
  // Only advance if this driver is the current offeree.
  if (!r || r.status !== "requested" || r.offeredTo !== uid) return { ok: true };
  const res = await offerNext(rideId);
  if (res.offerSeq) await enqueueTick(rideId, res.offerSeq);
  return { ok: true };
});

exports.cancelRide = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const rideId = req.data?.rideId;
  if (!rideId) throw new HttpsError("invalid-argument", "rideId required.");

  const ref = ridesRef().doc(rideId);
  await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r) return;
    if (r.riderId !== uid && r.driverId !== uid) {
      throw new HttpsError("permission-denied", "Not your ride.");
    }
    if (["completed", "cancelled", "expired"].includes(r.status)) return;
    txn.update(ref, { status: "cancelled", offeredTo: null, cancelledBy: uid });
  });
  return { ok: true };
});

/**
 * Driver completes the trip — the money-critical settlement, server-only.
 *
 * Computes the final fare (quote + waiting fee) authoritatively, splits out
 * platform commission, and records the outcome on the ride + driver ledger.
 *
 *  - cash: settled at completion — driver keeps the fare, owes commission,
 *      which is added to their ledger balance (the cash-debt the platform
 *      collects later).
 *  - card: marked `pending` here; the actual Paystack charge + confirmed
 *      earning entry land via the webhook in P2.
 */
exports.completeRide = onCall(
  { region: REGION, secrets: [paystack.PAYSTACK_SECRET_KEY] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const rideId = req.data?.rideId;
    if (!rideId) throw new HttpsError("invalid-argument", "rideId required.");

    const cfg = await readPricing();
    const ref = ridesRef().doc(rideId);

    // Phase 1: stamp the trip complete + compute money inside a transaction.
    const result = await db().runTransaction(async (txn) => {
      const snap = await txn.get(ref);
      const r = snap.data();
      if (!r) throw new HttpsError("not-found", "Ride not found.");
      if (r.driverId !== uid) {
        throw new HttpsError("permission-denied", "Not your ride.");
      }
      if (r.status === "completed") {
        return { finalFare: r.finalFare, alreadyDone: true };
      }
      if (r.status !== "in_progress") {
        throw new HttpsError("failed-precondition", "Trip is not in progress.");
      }

      const waitFee = computeWaitFee(r.arrivedAt, r.startedAt, cfg);
      const quoted =
        typeof r.quotedFare === "number" ? r.quotedFare : r.fare || 0;
      const { finalFare, commission, driverEarning } = splitFare(
        quoted + waitFee,
        cfg
      );
      const method = r.paymentMethod || "cash";
      const cash = method === "cash";
      const isWallet = method === "wallet";

      // Wallet pays from the rider's prepaid balance — read it before any
      // writes (Firestore requires all reads first in a transaction).
      let walletRef = null;
      let walletPaid = false;
      if (isWallet) {
        walletRef = db().collection("wallets").doc(r.riderId);
        const wsnap = await txn.get(walletRef);
        walletPaid = (wsnap.data()?.balance || 0) >= finalFare;
      }

      const paymentStatus = cash
        ? "cash"
        : isWallet
          ? walletPaid
            ? "paid"
            : "due"
          : "processing";

      txn.update(ref, {
        status: "completed",
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
        waitFee,
        finalFare,
        commission,
        driverEarning,
        // cash: settled now. card: 'processing' until the webhook confirms.
        // wallet: 'paid' if the balance covered it, else 'due'.
        paymentStatus,
      });

      // Cash settles immediately: record the earning + the commission debt.
      if (cash) {
        const ledgerRef = db().collection("ledgers").doc(uid);
        const entryRef = ledgerRef.collection("entries").doc();
        txn.set(
          ledgerRef,
          {
            balance: admin.firestore.FieldValue.increment(commission),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        txn.set(entryRef, {
          type: "cash_commission_due",
          rideId,
          method,
          finalFare,
          commission,
          driverEarning,
          balanceDelta: commission,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      // Wallet covered the fare: deduct it, record rider + driver entries.
      if (isWallet && walletPaid) {
        txn.set(
          walletRef,
          {
            balance: admin.firestore.FieldValue.increment(-finalFare),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        txn.set(walletRef.collection("entries").doc(), {
          type: "ride_payment",
          rideId,
          amount: finalFare,
          balanceDelta: -finalFare,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Driver earning recorded for the dashboard (cash-debt unchanged).
        const dEntry = db()
          .collection("ledgers")
          .doc(uid)
          .collection("entries")
          .doc();
        txn.set(dEntry, {
          type: "trip_earning_wallet",
          rideId,
          method: "wallet",
          finalFare,
          commission,
          driverEarning,
          balanceDelta: 0,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        txn.set(db().collection("transactions").doc(`wallet_trip_${rideId}`), {
          reference: `wallet_trip_${rideId}`,
          rideId,
          riderId: r.riderId,
          driverId: uid,
          amount: finalFare,
          commission,
          driverEarning,
          method: "wallet",
          type: "trip",
          status: "success",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      return {
        finalFare,
        commission,
        driverEarning,
        method,
        cash,
        isWallet,
        riderId: r.riderId,
      };
    });

    // Phase 2 (card only, outside the txn): charge the vaulted card with the
    // commission split. The webhook flips paymentStatus → paid and records the
    // earning; if we can't even initiate, mark the ride payment_due.
    if (!result.cash && !result.isWallet && !result.alreadyDone) {
      try {
        await chargeTripCard({
          rideId,
          riderId: result.riderId,
          driverId: uid,
          finalFare: result.finalFare,
          commission: result.commission,
          cfg,
        });
      } catch (e) {
        logger.error("trip card charge failed to initiate", {
          rideId,
          msg: e?.message,
        });
        await ref.update({ paymentStatus: "due" }).catch(() => {});
      }
    }

    return { ok: true, ...result };
  }
);

/** Initiate a server-side card charge for a completed trip, split to driver. */
async function chargeTripCard({ rideId, riderId, driverId, finalFare, commission, cfg }) {
  // Rider's default (or first) vaulted card.
  const pmSnap = await db()
    .collection("users")
    .doc(riderId)
    .collection("payment_methods")
    .orderBy("isDefault", "desc")
    .limit(1)
    .get();
  if (pmSnap.empty) throw new Error("no card on file");
  const card = pmSnap.docs[0].data();

  // Driver's payout subaccount (auto-split). Absent → charge without split;
  // the platform settles the driver via the ledger instead.
  const appSnap = await db().collection("applications").doc(driverId).get();
  const subaccount = appSnap.data()?.subaccountCode || null;

  const userSnap = await db().collection("users").doc(riderId).get();
  const email = card.email || userSnap.data()?.email;
  if (!email) throw new Error("no rider email for receipt");

  await paystack.chargeAuthorization({
    email,
    authorizationCode: card.authorizationCode,
    amountZar: finalFare,
    reference: `trip_${rideId}_${Date.now()}`,
    subaccount,
    // We keep the commission; the subaccount keeps the remainder.
    transactionChargeZar: subaccount ? commission : undefined,
    metadata: { purpose: "trip", rideId, riderId, driverId },
  });
}

/** Read-only pricing config for clients (preview) + tooling. */
exports.getPricing = onCall({ region: REGION }, async () => {
  return readPricing();
});

/**
 * Maintain each driver's aggregate rating. When a rider first sets `riderRating`
 * on a completed ride, roll it into the driver's running average on their user
 * doc (`ratingSum`, `ratingCount`, `ratingAvg`) — what `acceptRide` stamps onto
 * future rides for the assigned-driver card.
 */
exports.onDriverRated = onDocumentUpdated(
  { region: REGION, document: "rides/{rideId}" },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};
    const stars = Number(after.riderRating);
    // Count only the first rating per ride (ignore edits to avoid double count).
    if (!stars || before.riderRating) return;
    const driverId = after.driverId;
    if (!driverId) return;

    const userRef = db().collection("users").doc(driverId);
    await db().runTransaction(async (txn) => {
      const snap = await txn.get(userRef);
      const d = snap.data() || {};
      const count = (d.ratingCount || 0) + 1;
      const sum = (d.ratingSum || 0) + stars;
      txn.set(
        userRef,
        {
          ratingCount: count,
          ratingSum: sum,
          ratingAvg: Math.round((sum / count) * 100) / 100,
        },
        { merge: true }
      );
    });
  }
);

/**
 * Dispatch scheduled (advance-booked) rides when their time comes. Runs every
 * minute: any `scheduled` ride whose `scheduledFor` has passed is flipped to
 * `requested` and dispatched through the normal driver-offer flow.
 */
exports.dispatchScheduledRides = onSchedule(
  { region: REGION, schedule: "every 1 minutes" },
  async () => {
    const now = admin.firestore.Timestamp.now();
    const snap = await ridesRef()
      .where("status", "==", "scheduled")
      .where("scheduledFor", "<=", now)
      .get();
    if (snap.empty) return;

    for (const doc of snap.docs) {
      await doc.ref.update({
        status: "requested",
        dispatchedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await beginDispatch(doc.ref, doc.data());
    }
    logger.info(`dispatched ${snap.size} scheduled ride(s)`);
  }
);

// Backstop: any request that somehow never resolved gets expired.
exports.expireStaleRides = onSchedule(
  { region: REGION, schedule: "every 2 minutes" },
  async () => {
    const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - 3 * 60 * 1000);
    const snap = await ridesRef()
      .where("status", "==", "requested")
      .where("dispatchedAt", "<", cutoff)
      .get();
    if (snap.empty) return;
    const batch = db().batch();
    snap.forEach((d) => batch.update(d.ref, { status: "expired", offeredTo: null }));
    await batch.commit();
    logger.info(`expired ${snap.size} stale ride(s)`);
  }
);
