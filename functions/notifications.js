/**
 * FCM push — the reliability layer. A ride app that only hears offers while
 * the screen is on is dead; these triggers wake the right phone at the right
 * moment. Notification-type messages so Android displays them natively when
 * the app is backgrounded/killed (foreground UX is already live via Firestore
 * streams).
 *
 * Tokens live at users/{uid}.fcmTokens (array, client-managed); dead tokens
 * are pruned after each send.
 */
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const REGION = "europe-west1";
const db = () => admin.firestore();

async function push(uid, title, body, data = {}) {
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
      android: {
        priority: "high",
        notification: { defaultSound: true, defaultVibrateTimings: true },
      },
      data: Object.fromEntries(
        Object.entries(data).map(([k, v]) => [k, String(v)])
      ),
    });
  } catch (e) {
    logger.warn("push send failed", { uid, msg: e?.message });
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

/** Data-only high-priority push — wakes the app's background handler so it can
 *  ring (CallKit) for an offer, even when backgrounded/killed. */
async function pushData(uid, data) {
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
      data: Object.fromEntries(
        Object.entries(data).map(([k, v]) => [k, String(v)])
      ),
      android: { priority: "high" },
      apns: {
        headers: { "apns-priority": "10" },
        payload: { aps: { contentAvailable: true } },
      },
    });
  } catch (e) {
    logger.warn("pushData failed", { uid, msg: e?.message });
  }
}

const rand = (n) => Math.round(Number(n) || 0);

exports.onRideNotify = onDocumentUpdated(
  { region: REGION, document: "rides/{rideId}" },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};
    const rideId = event.params.rideId;

    // A fresh offer landed on a driver — ring (data message → CallKit).
    if (after.offeredTo && after.offeredTo !== before.offeredTo) {
      await pushData(after.offeredTo, {
        type: "offer",
        rideId,
        fare: rand(after.fare),
        distanceKm: (after.distanceKm || 0).toFixed(1),
        subtitle: `R${rand(after.fare)} · ${(after.distanceKm || 0).toFixed(1)} km`,
      });
    }

    // Trip status transitions → keep the rider in the loop off-screen.
    if (after.status !== before.status) {
      const rider = after.riderId;
      const driver = after.driverId;
      const total = rand(after.finalFare || after.fare);
      switch (after.status) {
        case "accepted":
          await push(
            rider,
            "Driver on the way",
            `${after.driverName || "Your driver"} · ${after.driverVehicle || "vehicle"}`,
            { type: "ride", rideId }
          );
          break;
        case "arriving":
          await push(rider, "Your driver is nearby",
            "Please get ready at the pickup point.", { type: "ride", rideId });
          break;
        case "arrived":
          await push(rider, "Your driver has arrived",
            "Free waiting time: 5 minutes.", { type: "ride", rideId });
          break;
        case "completed": {
          const completeMsg = after.paymentMethod === "card"
            ? `R${total} — charging your card.`
            : after.paymentMethod === "wallet"
              ? `R${total} paid from your Sift wallet.`
              : `Please pay R${total} cash to your driver.`;
          await push(rider, "Trip complete", completeMsg, { type: "ride", rideId });
          break;
        }
        case "cancelled": {
          const by = after.cancelledBy;
          if (by === after.riderId && driver) {
            await push(driver, "Ride cancelled",
              "The rider cancelled this trip.", { type: "ride", rideId });
          } else if (rider) {
            await push(rider, "Ride cancelled",
              "Your driver cancelled. Request another ride.",
              { type: "ride", rideId });
          }
          break;
        }
        case "expired":
          await push(rider, "No drivers available",
            "Try requesting again in a few minutes.", { type: "ride", rideId });
          break;
      }
    }

    // Card outcome → rider.
    if (after.paymentStatus !== before.paymentStatus) {
      if (after.paymentStatus === "paid") {
        await push(after.riderId, "Payment successful",
          `R${rand(after.finalFare)} paid by card. Thanks for riding with Sift.`,
          { type: "ride", rideId });
      } else if (after.paymentStatus === "due") {
        await push(after.riderId, "Card payment failed",
          "Open Sift to settle your trip and keep riding.",
          { type: "ride", rideId });
      }
    }
  }
);

exports.onApplicationNotify = onDocumentUpdated(
  { region: REGION, document: "applications/{uid}" },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};
    if (before.status === after.status) return;
    const uid = event.params.uid;
    if (after.status === "approved") {
      await push(uid, "You're approved! 🎉",
        "Go online and start earning with Sift.", { type: "application" });
    } else if (after.status === "rejected") {
      await push(uid, "Application update",
        after.rejectionReason ||
          "Your application needs attention. Open Sift for details.",
        { type: "application" });
    }
  }
);

exports.onParcelNotify = onDocumentUpdated(
  { region: REGION, document: "parcels/{parcelId}" },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};
    const parcelId = event.params.parcelId;

    // Fresh offer to a driver → ring (data message → CallKit).
    if (after.offeredTo && after.offeredTo !== before.offeredTo) {
      const stops = (after.stops || []).length;
      await pushData(after.offeredTo, {
        type: "offer",
        parcelId,
        subtitle: `${stops} drop-off${stops === 1 ? "" : "s"} · R${rand(after.fare)}`,
      });
    }

    // Status changes → the sender (order updates).
    if (after.status !== before.status) {
      const sender = after.senderId;
      const delivered = (after.stops || []).filter(
        (s) => s && s.status === "delivered"
      ).length;
      switch (after.status) {
        case "accepted":
          await push(sender, "Driver assigned 📦",
            `${after.driverName || "A driver"} is on the way to collect your parcel.`,
            { type: "parcel", parcelId });
          break;
        case "delivering":
          await push(sender, "Parcel collected",
            "Your parcel is on its way to the drop-offs.",
            { type: "parcel", parcelId });
          break;
        case "completed":
          await push(sender, "Deliveries complete ✅",
            `${delivered} of ${(after.stops || []).length} delivered.`,
            { type: "parcel", parcelId });
          break;
        case "cancelled":
          await push(sender, "Parcel cancelled",
            "Your parcel delivery was cancelled.", { type: "parcel", parcelId });
          break;
        case "expired":
          await push(sender, "No driver available",
            "We couldn't find a driver. Please try again shortly.",
            { type: "parcel", parcelId });
          break;
      }
    }
  }
);
