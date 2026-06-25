/**
 * One-off: seed/refresh the admin-editable `config/pricing` document.
 * Uses merge so it never clobbers values the admin has already tuned.
 *
 *   node scripts/seedPricing.js
 */
const path = require("path");
const admin = require("firebase-admin");
const { DEFAULTS } = require("../pricing");

const keyPath = path.join(
  __dirname,
  "..",
  "..",
  "sift_admin",
  "serviceAccountKey.json"
);
admin.initializeApp({ credential: admin.credential.cert(require(keyPath)) });

(async () => {
  await admin
    .firestore()
    .collection("config")
    .doc("pricing")
    .set(
      { ...DEFAULTS, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
      { merge: true }
    );
  console.log("Seeded config/pricing:", DEFAULTS);
  process.exit(0);
})().catch((e) => {
  console.error("Seed failed:", e);
  process.exit(1);
});
