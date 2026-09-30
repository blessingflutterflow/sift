/**
 * In-app chat push (contract deliverable #11). When a new message lands on a
 * ride, notify the *other* party so they see it even with the app backgrounded.
 * Messages live at rides/{rideId}/messages/{id}; chat history streams live on
 * the client via Firestore, so this is purely the wake-the-phone layer.
 */
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const REGION = "europe-west1";
const db = () => admin.firestore();

async function push(uid, title, body, data) {
  if (!uid) return;
  let tokens = [];
  try {
    const u = await db().collection("users").doc(uid).get();
    tokens = (u.data()?.fcmTokens || []).filter(Boolean);
  } catch (_) {
    return;
  }
  if (!tokens.length) return;
  try {
    await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      android: { priority: "high", notification: { defaultSound: true } },
      data: Object.fromEntries(
        Object.entries(data).map(([k, v]) => [k, String(v)])
      ),
    });
  } catch (e) {
    logger.warn("chat push failed", { uid, msg: e?.message });
  }
}

exports.onMessageCreated = onDocumentCreated(
  { region: REGION, document: "rides/{rideId}/messages/{messageId}" },
  async (event) => {
    const msg = event.data?.data();
    if (!msg) return;
    const rideId = event.params.rideId;

    const rideSnap = await db().collection("rides").doc(rideId).get();
    const r = rideSnap.data();
    if (!r) return;

    // Recipient = whichever party didn't send this message.
    const recipient =
      msg.senderId === r.riderId ? r.driverId : r.riderId;
    if (!recipient) return;

    const senderName =
      msg.senderRole === "driver"
        ? r.driverName || "Your driver"
        : r.riderName || "Your rider";
    const preview =
      (msg.text || "").length > 80
        ? `${msg.text.slice(0, 80)}…`
        : msg.text || "New message";

    await push(recipient, senderName, preview, { type: "chat", rideId });
  }
);

/** Support reply (admin → user): wake the user's phone. Thread id == user uid. */
exports.onSupportMessage = onDocumentCreated(
  { region: REGION, document: "support_threads/{uid}/messages/{messageId}" },
  async (event) => {
    const msg = event.data?.data();
    if (!msg || msg.senderRole !== "admin") return; // only notify on admin replies
    const uid = event.params.uid;
    const preview =
      (msg.text || "").length > 80
        ? `${msg.text.slice(0, 80)}…`
        : msg.text || "New message";
    await push(uid, "Sift Support", preview, { type: "support" });
  }
);
