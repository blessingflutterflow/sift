/**
 * Account deletion — Play Store requires an in-app path. Removes identity and
 * personal data; financial records (rides, ledgers, transactions) are
 * retained for bookkeeping but the auth account and profile are gone.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const REGION = "europe-west1";
const ACTIVE = ["requested", "accepted", "arriving", "arrived", "in_progress"];

exports.deleteAccount = onCall({ region: REGION }, async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();

  // No deleting mid-trip.
  const [asRider, asDriver] = await Promise.all([
    db.collection("rides")
      .where("riderId", "==", uid)
      .where("status", "in", ACTIVE)
      .limit(1)
      .get(),
    db.collection("rides")
      .where("driverId", "==", uid)
      .where("status", "in", ACTIVE)
      .limit(1)
      .get(),
  ]);
  if (!asRider.empty || !asDriver.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Finish or cancel your active trip first."
    );
  }

  // Profile + subcollections (cards, places), application, live location.
  await db.recursiveDelete(db.collection("users").doc(uid));
  await db.collection("applications").doc(uid).delete().catch(() => {});
  await db.collection("driver_locations").doc(uid).delete().catch(() => {});

  // Finally the auth user — the client signs out on success.
  await admin.auth().deleteUser(uid);
  logger.info("account deleted", { uid });
  return { ok: true };
});
