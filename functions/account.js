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

/**
 * Save the signed-in user's profile (name, email, role, phone) server-side.
 *
 * The app used to write this straight to Firestore from the client, but a
 * flaky/blocked client write left accounts with no name/role — they showed as
 * "Unnamed / Unknown" in admin. Writing it via the Admin SDK here is reliable
 * (no client offline hang, no rules/App-Check surprise), so the name always
 * lands. enforceAppCheck:false matches the OTP flow during the testing phase.
 */
exports.saveProfile = onCall(
  { region: REGION, enforceAppCheck: false },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const db = admin.firestore();
    const d = req.data || {};

    const name = String(d.name || "").trim();
    const email = String(d.email || "").trim();
    const phone = String(d.phone || "").trim();
    const role = d.role === "rider" || d.role === "driver" ? d.role : null;

    const patch = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    if (name) patch.name = name;
    if (email) patch.email = email;
    if (phone) patch.phone = phone;
    if (role) {
      patch.role = role;
      // Riders are usable immediately; drivers stay 'none' until docs are
      // reviewed. Never downgrade an already-approved account.
      if (role === "rider") patch.status = "approved";
    }

    await db.collection("users").doc(uid).set(patch, { merge: true });
    return { ok: true };
  }
);

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
