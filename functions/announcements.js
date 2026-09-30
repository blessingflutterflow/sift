/**
 * Admin broadcasts → drivers / riders / specific people.
 *
 * The admin dashboard writes an `announcements/{id}` doc; the app streams active
 * ones addressed to the current user and shows them full-screen (persistent
 * until each user dismisses). This trigger is the wake layer — it pushes a
 * notification so people not in the app find out and can tap to open:
 *   • all_drivers → FCM topic "drivers"
 *   • all_riders  → FCM topic "riders"
 *   • everyone    → both topics
 *   • specific    → a per-uid push to each targetUid
 * Drivers/riders subscribe to their role topic from the app on login.
 */
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const REGION = "europe-west1";
const db = () => admin.firestore();

const androidCfg = {
  priority: "high",
  notification: { defaultSound: true, defaultVibrateTimings: true },
};

/** Push to one user's devices (their fcmTokens); prune dead tokens after. */
async function pushToUid(uid, title, body, data) {
  if (!uid) return;
  let tokens = [];
  try {
    const u = await db().collection("users").doc(uid).get();
    tokens = (u.data()?.fcmTokens || []).filter(Boolean);
  } catch (_) {
    return;
  }
  if (!tokens.length) return;
  let res;
  try {
    res = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      android: androidCfg,
      data,
    });
  } catch (e) {
    logger.warn("announcement per-uid push failed", { uid, msg: e?.message });
    return;
  }
  const dead = [];
  res.responses.forEach((r, i) => {
    const code = r.error?.code || "";
    if (
      code.includes("registration-token-not-registered") ||
      code.includes("invalid-registration-token") ||
      code.includes("invalid-argument")
    ) {
      dead.push(tokens[i]);
    }
  });
  if (dead.length) {
    await db()
      .collection("users")
      .doc(uid)
      .update({ fcmTokens: admin.firestore.FieldValue.arrayRemove(...dead) })
      .catch(() => {});
  }
}

exports.onAnnouncementCreated = onDocumentCreated(
  { region: REGION, document: "announcements/{annId}" },
  async (event) => {
    const a = event.data?.data();
    if (!a) return;
    // Only push for live broadcasts (admin can stage one inactive).
    if (a.active === false) return;

    const title = String(a.title || "Sift announcement");
    const body = String(a.body || "");
    const audience = String(a.audience || "all_drivers");
    const data = {
      type: "announcement",
      announcementId: event.params.annId,
      severity: String(a.severity || "info"),
    };

    try {
      if (audience === "specific") {
        const uids = Array.isArray(a.targetUids) ? a.targetUids : [];
        await Promise.all(uids.map((uid) => pushToUid(uid, title, body, data)));
        return;
      }
      const topics =
        audience === "everyone"
          ? ["drivers", "riders"]
          : audience === "all_riders"
            ? ["riders"]
            : ["drivers"];
      await Promise.all(
        topics.map((topic) =>
          admin.messaging().send({
            topic,
            notification: { title, body },
            android: androidCfg,
            data,
          })
        )
      );
    } catch (e) {
      logger.warn("announcement push failed", {
        annId: event.params.annId,
        msg: e?.message,
      });
    }
  }
);
