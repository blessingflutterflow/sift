/**
 * Parcel delivery — multi-stop. Mirrors the ride dispatch model but on the
 * `parcels` collection, with per-stop proof-of-delivery and a size/weight fare.
 *
 *  onParcelRequested (trigger)   — stamp authoritative fare, rank + offer.
 *  parcelDispatchTick (Task)     — advance the offer at the deadline.
 *  acceptParcel/declineParcel/cancelParcel (callables).
 *  pickUpParcel                  — driver collected the parcel.
 *  deliverParcelStop/failParcelStop — per-drop-off outcome (+ POD); when every
 *      stop is resolved the parcel settles (money) and completes.
 *  expireStaleParcels (scheduled) — backstop sweeper.
 */
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onTaskDispatched } = require("firebase-functions/v2/tasks");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFunctions } = require("firebase-admin/functions");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const { splitFare } = require("./pricing");
const { readParcelPricing, computeParcelFare } = require("./parcelPricing");
const paystack = require("./paystack");

const REGION = "europe-west1";
const OFFER_SECONDS = 20;
const MAX_CANDIDATES = 6;
const MAX_RADIUS_KM = 20;
const STALE_MS = 3 * 60 * 1000; // ignore drivers not seen in 3 min (app heartbeats every 40s)
const ACTIVE_RIDE = ["accepted", "arriving", "arrived", "in_progress"];
const ACTIVE_PARCEL = ["accepted", "arriving", "picked_up", "delivering"];

const db = () => admin.firestore();
const parcelsRef = () => db().collection("parcels");

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

/** Online drivers not already busy on a ride or parcel, near the pickup. */
async function rankCandidates(pickup) {
  const [online, rides, parcels] = await Promise.all([
    db().collection("driver_locations").where("online", "==", true).get(),
    db().collection("rides").where("status", "in", ACTIVE_RIDE).get(),
    parcelsRef().where("status", "in", ACTIVE_PARCEL).get(),
  ]);
  const busy = new Set();
  rides.forEach((d) => d.data().driverId && busy.add(d.data().driverId));
  parcels.forEach((d) => d.data().driverId && busy.add(d.data().driverId));

  const cands = [];
  online.forEach((doc) => {
    const x = doc.data();
    if (busy.has(doc.id)) return;
    if (typeof x.lat !== "number" || typeof x.lng !== "number") return;
    // Skip "ghost online" drivers (app died without going offline).
    const seen = x.updatedAt?.toMillis?.() ?? 0;
    if (Date.now() - seen > STALE_MS) return;
    // Parcels go to ANY online driver regardless of category — a Bike, Go, XL
    // or Max driver can all carry a parcel, so restricting to 'parcel' drivers
    // only starved the queue.
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
    `locations/${REGION}/functions/parcelDispatchTick`
  );
}

async function enqueueTick(parcelId, offerSeq) {
  await tickQueue().enqueue(
    { parcelId, offerSeq },
    { scheduleDelaySeconds: OFFER_SECONDS + 2 }
  );
}

async function offerNext(parcelId) {
  const ref = parcelsRef().doc(parcelId);
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

async function beginDispatch(ref, parcel) {
  const parcelId = ref.id;
  try {
    const [u, cfg] = await Promise.all([
      db().collection("users").doc(parcel.senderId).get(),
      readParcelPricing(),
    ]);
    const ud = u.data() || {};
    if (ud.blocked === true) {
      await ref.update({ status: "expired", expiredReason: "sender_blocked" });
      return;
    }
    const quotedFare = computeParcelFare(parcel.distanceKm, parcel.stops, cfg);
    await ref.update({
      senderName: ud.name || "Sender",
      senderPhone: ud.phone || "",
      quotedFare,
      fare: quotedFare,
      commissionPct: cfg.commissionPct,
      paymentMethod: parcel.paymentMethod || "cash",
      paymentStatus: "unpaid",
    });
  } catch (e) {
    logger.warn("parcel fare stamp failed", e);
  }

  const candidates = await rankCandidates({
    lat: parcel.pickupLat,
    lng: parcel.pickupLng,
  });
  if (candidates.length === 0) {
    await ref.update({ status: "expired", candidateIds: [], candidateIndex: -1 });
    return;
  }
  await ref.update({
    candidateIds: candidates.map((c) => c.uid),
    candidatePositions: candidates.map((c) => ({ lat: c.lat, lng: c.lng })),
    candidateIndex: -1,
    offerSeq: 0,
    dispatchedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const res = await offerNext(parcelId);
  if (res.offerSeq) await enqueueTick(parcelId, res.offerSeq);
}

exports.onParcelRequested = onDocumentCreated(
  { region: REGION, document: "parcels/{parcelId}" },
  async (event) => {
    const snap = event.data;
    const parcel = snap.data();
    if (!parcel || parcel.status !== "requested") return;
    await beginDispatch(snap.ref, parcel);
  }
);

exports.parcelDispatchTick = onTaskDispatched(
  { region: REGION, retryConfig: { maxAttempts: 3 }, rateLimits: { maxConcurrentDispatches: 50 } },
  async (req) => {
    const { parcelId, offerSeq } = req.data || {};
    if (!parcelId) return;
    const snap = await parcelsRef().doc(parcelId).get();
    const r = snap.data();
    if (!r || r.status !== "requested") return;
    if ((r.offerSeq ?? 0) !== offerSeq) return;
    const res = await offerNext(parcelId);
    if (res.offerSeq) await enqueueTick(parcelId, res.offerSeq);
  }
);

exports.acceptParcel = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const parcelId = req.data?.parcelId;
  if (!parcelId) throw new HttpsError("invalid-argument", "parcelId required.");

  const [u, a] = await Promise.all([
    db().collection("users").doc(uid).get(),
    db().collection("applications").doc(uid).get(),
  ]);
  if (u.data()?.blocked === true) {
    throw new HttpsError("permission-denied", "Your account is blocked.");
  }
  const ud = u.data() || {};
  const v = a.data()?.vehicle || {};
  const vehicle =
    [v.color, v.make, v.model].filter(Boolean).join(" ") || "Vehicle";
  const ratingCount = ud.ratingCount || 0;

  const ref = parcelsRef().doc(parcelId);
  const ok = await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r || r.status !== "requested") return false;
    if (r.offeredTo !== uid) return false;
    if (r.offerExpiresAt && r.offerExpiresAt.toMillis() < Date.now()) return false;
    txn.update(ref, {
      status: "accepted",
      driverId: uid,
      driverName: ud.name || "Driver",
      driverPhone: ud.phone || "",
      driverVehicle: vehicle,
      driverPhoto: a.data()?.documents?.photo || null,
      driverRating: ratingCount > 0 ? ud.ratingAvg || null : null,
      offeredTo: null,
      acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!ok) throw new HttpsError("failed-precondition", "No longer available.");
  return { ok: true };
});

exports.declineParcel = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const parcelId = req.data?.parcelId;
  if (!parcelId) throw new HttpsError("invalid-argument", "parcelId required.");
  const snap = await parcelsRef().doc(parcelId).get();
  const r = snap.data();
  if (!r || r.status !== "requested" || r.offeredTo !== uid) return { ok: true };
  const res = await offerNext(parcelId);
  if (res.offerSeq) await enqueueTick(parcelId, res.offerSeq);
  return { ok: true };
});

exports.cancelParcel = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const parcelId = req.data?.parcelId;
  if (!parcelId) throw new HttpsError("invalid-argument", "parcelId required.");
  const ref = parcelsRef().doc(parcelId);
  await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r) return;
    if (r.senderId !== uid && r.driverId !== uid) {
      throw new HttpsError("permission-denied", "Not your parcel.");
    }
    if (["completed", "cancelled", "expired"].includes(r.status)) return;
    // Don't allow cancel once the driver has collected the parcel.
    if (["picked_up", "delivering"].includes(r.status)) {
      throw new HttpsError("failed-precondition", "Parcel already collected.");
    }
    txn.update(ref, { status: "cancelled", offeredTo: null, cancelledBy: uid });
  });
  return { ok: true };
});

exports.pickUpParcel = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const parcelId = req.data?.parcelId;
  if (!parcelId) throw new HttpsError("invalid-argument", "parcelId required.");
  const ref = parcelsRef().doc(parcelId);
  await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r || r.driverId !== uid) {
      throw new HttpsError("permission-denied", "Not your parcel.");
    }
    if (!["accepted", "arriving"].includes(r.status)) {
      throw new HttpsError("failed-precondition", "Parcel not ready for pickup.");
    }
    txn.update(ref, {
      status: "delivering",
      pickedUpAt: admin.firestore.FieldValue.serverTimestamp(),
      currentStopIndex: 0,
    });
  });
  return { ok: true };
});

/**
 * Resolve one drop-off (delivered or failed). When every stop is resolved the
 * parcel settles + completes. Cash/wallet settle inside the txn; card returns a
 * flag so the charge is initiated afterwards.
 */
async function resolveStop(uid, parcelId, stopIndex, patch) {
  const ref = parcelsRef().doc(parcelId);
  const cfg = await readParcelPricing();

  const result = await db().runTransaction(async (txn) => {
    const s = await txn.get(ref);
    const r = s.data();
    if (!r) throw new HttpsError("not-found", "Parcel not found.");
    if (r.driverId !== uid) {
      throw new HttpsError("permission-denied", "Not your parcel.");
    }
    if (r.status !== "delivering") {
      throw new HttpsError("failed-precondition", "Parcel not in delivery.");
    }
    const stops = Array.isArray(r.stops) ? [...r.stops] : [];
    if (stopIndex < 0 || stopIndex >= stops.length) {
      throw new HttpsError("invalid-argument", "Bad stop index.");
    }
    if (stops[stopIndex].status !== "pending") {
      return { alreadyDone: true };
    }
    stops[stopIndex] = {
      ...stops[stopIndex],
      ...patch,
      // Concrete timestamp, NOT serverTimestamp(): the FieldValue sentinel is
      // illegal inside an array element and made the whole completion write
      // fail ("Could not record this delivery").
      deliveredAt: admin.firestore.Timestamp.now(),
    };
    const nextPending = stops.findIndex((x) => x.status === "pending");
    const allResolved = nextPending === -1;

    // Wallet needs reading before any write.
    const method = r.paymentMethod || "cash";
    const finalFare =
      typeof r.quotedFare === "number" ? r.quotedFare : r.fare || 0;
    let walletRef = null;
    let walletPaid = false;
    if (allResolved && method === "wallet") {
      walletRef = db().collection("wallets").doc(r.senderId);
      const w = await txn.get(walletRef);
      walletPaid = (w.data()?.balance || 0) >= finalFare;
    }

    const update = {
      stops,
      currentStopIndex: allResolved ? stops.length : nextPending,
    };

    if (!allResolved) {
      txn.update(ref, update);
      return { resolved: true };
    }

    // All stops resolved → settle + complete.
    const { commission, driverEarning } = splitFare(finalFare, cfg);
    update.status = "completed";
    update.completedAt = admin.firestore.FieldValue.serverTimestamp();
    update.finalFare = finalFare;
    update.commission = commission;
    update.driverEarning = driverEarning;

    const cash = method === "cash";
    const wallet = method === "wallet";
    update.paymentStatus = cash
      ? "cash"
      : wallet
        ? walletPaid
          ? "paid"
          : "due"
        : "processing";
    txn.update(ref, update);

    if (cash) {
      const ledgerRef = db().collection("ledgers").doc(uid);
      txn.set(
        ledgerRef,
        {
          balance: admin.firestore.FieldValue.increment(commission),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      txn.set(ledgerRef.collection("entries").doc(), {
        type: "cash_commission_due",
        parcelId,
        method: "cash",
        finalFare,
        commission,
        driverEarning,
        balanceDelta: commission,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    if (wallet && walletPaid) {
      txn.set(
        walletRef,
        {
          balance: admin.firestore.FieldValue.increment(-finalFare),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      txn.set(walletRef.collection("entries").doc(), {
        type: "parcel_payment",
        parcelId,
        amount: finalFare,
        balanceDelta: -finalFare,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      txn.set(db().collection("ledgers").doc(uid).collection("entries").doc(), {
        type: "parcel_earning_wallet",
        parcelId,
        method: "wallet",
        finalFare,
        commission,
        driverEarning,
        balanceDelta: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    return {
      completed: true,
      cardCharge: method === "card",
      finalFare,
      commission,
      senderId: r.senderId,
    };
  });

  // Card charge (outside the txn) — webhook flips paymentStatus → paid.
  if (result.cardCharge) {
    try {
      await chargeParcelCard({
        parcelId,
        senderId: result.senderId,
        driverId: uid,
        finalFare: result.finalFare,
        commission: result.commission,
      });
    } catch (e) {
      logger.error("parcel card charge failed to initiate", { parcelId, msg: e?.message });
      await ref.update({ paymentStatus: "due" }).catch(() => {});
    }
  }
  return result;
}

async function chargeParcelCard({ parcelId, senderId, driverId, finalFare, commission }) {
  const pmSnap = await db()
    .collection("users")
    .doc(senderId)
    .collection("payment_methods")
    .orderBy("isDefault", "desc")
    .limit(1)
    .get();
  if (pmSnap.empty) throw new Error("no card on file");
  const card = pmSnap.docs[0].data();
  const appSnap = await db().collection("applications").doc(driverId).get();
  const subaccount = appSnap.data()?.subaccountCode || null;
  const userSnap = await db().collection("users").doc(senderId).get();
  const email = card.email || userSnap.data()?.email;
  if (!email) throw new Error("no sender email for receipt");

  await paystack.chargeAuthorization({
    email,
    authorizationCode: card.authorizationCode,
    amountZar: finalFare,
    reference: `parcel_${parcelId}_${Date.now()}`,
    subaccount,
    transactionChargeZar: subaccount ? commission : undefined,
    metadata: { purpose: "parcel", parcelId, senderId, driverId },
  });
}

exports.deliverParcelStop = onCall(
  { region: REGION, secrets: [paystack.PAYSTACK_SECRET_KEY] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const { parcelId, stopIndex, podPhotoUrl, podSignatureUrl, receivedBy } =
      req.data || {};
    if (!parcelId || typeof stopIndex !== "number") {
      throw new HttpsError("invalid-argument", "parcelId + stopIndex required.");
    }
    await resolveStop(uid, parcelId, stopIndex, {
      status: "delivered",
      podPhotoUrl: podPhotoUrl || null,
      podSignatureUrl: podSignatureUrl || null,
      receivedBy: receivedBy || "",
    });
    return { ok: true };
  }
);

exports.failParcelStop = onCall(
  { region: REGION, secrets: [paystack.PAYSTACK_SECRET_KEY] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const { parcelId, stopIndex, reason } = req.data || {};
    if (!parcelId || typeof stopIndex !== "number") {
      throw new HttpsError("invalid-argument", "parcelId + stopIndex required.");
    }
    await resolveStop(uid, parcelId, stopIndex, {
      status: "failed",
      failReason: reason || "Delivery failed",
    });
    return { ok: true };
  }
);

// Backstop: requests that never got a driver get expired.
exports.expireStaleParcels = onSchedule(
  { region: REGION, schedule: "every 3 minutes" },
  async () => {
    const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - 4 * 60 * 1000);
    const snap = await parcelsRef()
      .where("status", "==", "requested")
      .where("dispatchedAt", "<", cutoff)
      .get();
    if (snap.empty) return;
    const batch = db().batch();
    snap.forEach((d) => batch.update(d.ref, { status: "expired", offeredTo: null }));
    await batch.commit();
    logger.info(`expired ${snap.size} stale parcel(s)`);
  }
);
