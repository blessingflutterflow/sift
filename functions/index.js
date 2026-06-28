/**
 * Sift Cloud Functions — phone verification via Twilio Verify.
 *
 * Flow:
 *   sendOtp(phone)        → Twilio sends an SMS code
 *   verifyOtp(phone,code) → Twilio checks the code; on success we get-or-create
 *                           a Firebase Auth user for that phone and return a
 *                           custom token the app signs in with.
 *
 * Twilio credentials are stored as Functions secrets (never in source):
 *   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_VERIFY_SERVICE_SID
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const twilio = require("twilio");

admin.initializeApp();

const TWILIO_ACCOUNT_SID = defineSecret("TWILIO_ACCOUNT_SID");
const TWILIO_AUTH_TOKEN = defineSecret("TWILIO_AUTH_TOKEN");
const TWILIO_VERIFY_SERVICE_SID = defineSecret("TWILIO_VERIFY_SERVICE_SID");

const REGION = "europe-west1";
const SECRETS = [
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_VERIFY_SERVICE_SID,
];

function twilioClient() {
  return twilio(TWILIO_ACCOUNT_SID.value(), TWILIO_AUTH_TOKEN.value());
}

/** Normalize to E.164-ish: strip spaces. The app sends "+44 7700900123". */
function normalizePhone(raw) {
  if (typeof raw !== "string") return null;
  const cleaned = raw.replace(/\s+/g, "");
  return /^\+[1-9]\d{6,14}$/.test(cleaned) ? cleaned : null;
}

// TESTING PHASE: App Check enforcement is OFF so sideloaded builds (client
// testers) work without registering debug tokens. The per-phone throttle
// below is the compensating control against SMS pumping. RE-ENABLE
// (enforceAppCheck: true) before launch, when builds ship via the Play
// internal testing track and Play Integrity attests automatically.
const OTP_THROTTLE = { minIntervalMs: 45 * 1000, maxPerHour: 6 };

/** Allow at most one send per 45s and 6 per hour per phone number. */
async function allowOtpSend(phone) {
  const ref = db().collection("otp_throttle").doc(phone);
  return db().runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    const now = Date.now();
    const sends = ((snap.data() || {}).sends || []).filter(
      (t) => now - t < 60 * 60 * 1000
    );
    if (sends.length >= OTP_THROTTLE.maxPerHour) return false;
    if (
      sends.length &&
      now - sends[sends.length - 1] < OTP_THROTTLE.minIntervalMs
    ) {
      return false;
    }
    sends.push(now);
    txn.set(ref, {
      sends,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
}

const db = () => admin.firestore();

exports.sendOtp = onCall(
  { region: REGION, secrets: SECRETS, enforceAppCheck: false },
  async (req) => {
  const phone = normalizePhone(req.data?.phone);
  logger.info("sendOtp", { raw: req.data?.phone, normalized: phone });
  if (!phone) {
    throw new HttpsError("invalid-argument", "A valid phone number is required.");
  }
  if (!(await allowOtpSend(phone))) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many codes requested. Please wait a minute and try again.",
    );
  }
  try {
    await twilioClient()
      .verify.v2.services(TWILIO_VERIFY_SERVICE_SID.value())
      .verifications.create({ to: phone, channel: "sms" });
    return { sent: true };
  } catch (err) {
    logger.error("sendOtp failed", err);
    throw new HttpsError("internal", "Could not send the verification code.");
  }
});

exports.verifyOtp = onCall(
  // TESTING PHASE: enforcement off (see sendOtp note). Twilio Verify itself
  // limits check attempts per verification, so brute force is bounded.
  { region: REGION, secrets: SECRETS, enforceAppCheck: false },
  async (req) => {
  const phone = normalizePhone(req.data?.phone);
  const code = req.data?.code;
  logger.info("verifyOtp", {
    raw: req.data?.phone,
    normalized: phone,
    codeLen: code ? String(code).length : 0,
  });
  if (!phone || !code) {
    throw new HttpsError("invalid-argument", "Phone and code are required.");
  }

  let check;
  try {
    check = await twilioClient()
      .verify.v2.services(TWILIO_VERIFY_SERVICE_SID.value())
      .verificationChecks.create({ to: phone, code: String(code) });
    logger.info("verifyOtp check status", { status: check.status });
  } catch (err) {
    logger.error("verifyOtp check failed", {
      twilioCode: err && err.code,
      message: err && err.message,
      phone,
    });
    // 20404 = no pending verification (expired or already used).
    if (err && err.code === 20404) {
      throw new HttpsError(
        "deadline-exceeded",
        "Your code expired. Request a new one.",
      );
    }
    throw new HttpsError("internal", "Could not verify the code.");
  }

  if (check.status !== "approved") {
    throw new HttpsError("unauthenticated", "The code is incorrect or expired.");
  }

  // Get-or-create the Firebase user keyed by phone number.
  let user;
  try {
    user = await admin.auth().getUserByPhoneNumber(phone);
  } catch (e) {
    if (e && e.code === "auth/user-not-found") {
      user = await admin.auth().createUser({ phoneNumber: phone });
    } else {
      logger.error("verifyOtp user lookup failed", e);
      throw new HttpsError("internal", "Could not complete sign-in.");
    }
  }

  const token = await admin.auth().createCustomToken(user.uid);
  return { token, uid: user.uid };
});

// Ride dispatch (orchestrator, Cloud Task tick, accept/decline/cancel, sweeper).
Object.assign(exports, require("./dispatch"));

// Paystack money flow (webhook, card vault, payouts, debt settlements).
Object.assign(exports, require("./payments"));

// FCM push (offers, trip status, payment outcomes, application decisions).
Object.assign(exports, require("./notifications"));

// Maps REST proxy (keeps the Directions/Places key out of the APK).
Object.assign(exports, require("./maps"));

// Account deletion (Play Store requirement).
Object.assign(exports, require("./account"));

// Emailed digital receipts (Resend) on trip settlement.
Object.assign(exports, require("./receipts"));

// In-app chat push (notify the other party of new messages).
Object.assign(exports, require("./chat"));

// Parcel delivery (multi-stop dispatch, POD, settlement).
Object.assign(exports, require("./parcels"));
