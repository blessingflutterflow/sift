/**
 * One-time seeding for the Play Store review demo accounts.
 *
 * Google reviewers sign in with the OTP-bypass test numbers (see TEST_NUMBERS
 * in index.js) but the accounts still need Firestore profiles set up so the
 * reviewer lands on the real app, not onboarding:
 *   • driver  → users.role='driver' + applications/{uid}.status='approved'
 *   • rider   → users.role='rider'  + users.verificationStatus='approved'
 *
 * Secured by a secret query param. Delete this function after seeding.
 */
const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const REGION = "europe-west1";
const SEED_SECRET = "sift-demo-seed-92f3a7";

exports.seedDemoAccounts = onRequest(
  { region: REGION, invoker: "public" },
  async (req, res) => {
    if (req.query.secret !== SEED_SECRET) {
      res.status(403).send("forbidden");
      return;
    }
    const db = admin.firestore();
    const now = () => admin.firestore.FieldValue.serverTimestamp();

    const demos = [
      {
        phone: "+27600000001",
        role: "driver",
        name: "Demo Driver",
        email: "demo.driver@sift.co.za",
      },
      {
        phone: "+27600000002",
        role: "rider",
        name: "Demo Rider",
        email: "demo.rider@sift.co.za",
      },
    ];

    const out = [];
    try {
      for (const d of demos) {
        let user;
        try {
          user = await admin.auth().getUserByPhoneNumber(d.phone);
        } catch (_) {
          user = await admin.auth().createUser({ phoneNumber: d.phone });
        }

        const patch = {
          name: d.name,
          email: d.email,
          phone: d.phone,
          role: d.role,
          status: "approved",
          blocked: false,
          updatedAt: now(),
        };
        if (d.role === "rider") patch.verificationStatus = "approved";
        await db.collection("users").doc(user.uid).set(patch, { merge: true });

        if (d.role === "driver") {
          // An approved application so the app routes to driver home, not docs.
          await db.collection("applications").doc(user.uid).set(
            {
              uid: user.uid,
              role: "driver",
              status: "approved",
              vehicle: {
                make: "Toyota",
                model: "Corolla",
                year: "2020",
                plate: "DEMO001GP",
                color: "White",
              },
              documents: {},
              submittedAt: now(),
            },
            { merge: true }
          );
        }

        out.push({ phone: d.phone, uid: user.uid, role: d.role });
      }
      res.json({ ok: true, seeded: out });
    } catch (e) {
      res.status(500).json({ ok: false, error: String(e && e.message) });
    }
  }
);
