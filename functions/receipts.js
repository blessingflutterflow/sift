/**
 * Emailed digital receipts (contract Screen 9). When a trip is settled —
 * card payment confirmed (`paymentStatus: 'paid'`) or a cash trip completed —
 * the rider gets an emailed fare-breakdown receipt. The in-app receipt already
 * exists; this is the email side.
 *
 * Sent via Resend (https://resend.com) using the global fetch in Node 22 — no
 * SDK dependency. The API key lives in Functions Secrets (RESEND_API_KEY).
 *
 * DELIVERABILITY / SPAM NOTE:
 *   `FROM` currently uses Resend's shared test sender. On the free tier without
 *   a verified domain, Resend only delivers to your own Resend-account email —
 *   fine for testing. For real riders, verify a domain in Resend (adds SPF/DKIM)
 *   and change FROM to e.g. "Sift <receipts@yourdomain>". That one change +
 *   the DNS records is what keeps receipts out of spam.
 */
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const RESEND_API_KEY = defineSecret("RESEND_API_KEY");
const REGION = "europe-west1";
const db = () => admin.firestore();

// --- Sender config (swap FROM to a verified-domain address for production) ---
const FROM = "Sift Receipts <onboarding@resend.dev>";
const REPLY_TO = "raymondtshoeu@gmail.com";

const rand = (n) => Math.round(Number(n) || 0);
const money = (n) => `R${(Number(n) || 0).toFixed(2)}`;

async function sendEmail({ to, subject, html }) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY.value()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: FROM,
      to: [to],
      reply_to: REPLY_TO,
      subject,
      html,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(body?.message || `Resend failed (${res.status})`);
  }
  return body;
}

/** Build the branded HTML receipt for a settled ride. */
function receiptHtml(rideId, r) {
  const total = r.finalFare ?? r.quotedFare ?? r.fare ?? 0;
  const waitFee = r.waitFee ?? 0;
  const tripFare = Math.max(0, total - waitFee);
  const method = (r.paymentMethod || "cash") === "card" ? "Card" : "Cash";
  const date = (r.completedAt?.toDate?.() || new Date()).toLocaleString("en-ZA", {
    dateStyle: "medium",
    timeStyle: "short",
  });
  const row = (label, value, strong) => `
    <tr>
      <td style="padding:8px 0;color:#777983;font-size:14px;">${label}</td>
      <td style="padding:8px 0;text-align:right;font-size:14px;${
        strong ? "font-weight:700;color:#2D2E39;" : "color:#2D2E39;"
      }">${value}</td>
    </tr>`;

  return `
  <div style="background:#f5f5f7;padding:24px;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;">
    <div style="max-width:480px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #ececf0;">
      <div style="background:#FF6B2C;padding:24px;color:#fff;">
        <div style="font-size:22px;font-weight:800;">Sift</div>
        <div style="opacity:.9;margin-top:4px;">Your trip receipt</div>
      </div>
      <div style="padding:24px;">
        <p style="margin:0 0 16px;color:#2D2E39;font-size:15px;">
          Thanks for riding with Sift. Here's the breakdown for your trip.
        </p>
        <table style="width:100%;border-collapse:collapse;">
          ${row("Date", date)}
          ${row("Driver", r.driverName || "—")}
          ${row("Vehicle", r.driverVehicle || "—")}
          ${row("Distance", `${(r.distanceKm || 0).toFixed(1)} km`)}
          <tr><td colspan="2" style="border-top:1px solid #ececf0;padding-top:8px;"></td></tr>
          ${row("Trip fare", money(tripFare))}
          ${waitFee > 0 ? row("Waiting fee", money(waitFee)) : ""}
          ${row("Total", money(total), true)}
          ${row("Payment", method)}
        </table>
        <p style="margin:20px 0 0;color:#a7aab2;font-size:12px;">
          Ride reference: ${rideId}
        </p>
      </div>
    </div>
    <p style="max-width:480px;margin:16px auto 0;color:#a7aab2;font-size:12px;text-align:center;">
      This is an automated receipt from Sift. Reply to this email if you have a question.
    </p>
  </div>`;
}

exports.onTripReceipt = onDocumentUpdated(
  { region: REGION, document: "rides/{rideId}", secrets: [RESEND_API_KEY] },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};
    const rideId = event.params.rideId;

    // Send once, on settlement: card → paymentStatus becomes 'paid';
    // cash → status becomes 'completed' on a cash trip.
    const newlyPaidCard =
      before.paymentStatus !== "paid" && after.paymentStatus === "paid";
    const newlyCompletedCash =
      before.status !== "completed" &&
      after.status === "completed" &&
      (after.paymentMethod || "cash") === "cash";
    if (!newlyPaidCard && !newlyCompletedCash) return;
    if (after.receiptSentAt) return; // idempotent — already emailed

    // Rider's email (set on their profile). No email → nothing to send.
    let email;
    try {
      const u = await db().collection("users").doc(after.riderId).get();
      email = u.data()?.email;
    } catch (_) {
      return;
    }
    if (!email) {
      logger.info("receipt skipped — rider has no email", { rideId });
      return;
    }

    try {
      await sendEmail({
        to: email,
        subject: `Your Sift receipt — ${money(after.finalFare ?? after.fare)}`,
        html: receiptHtml(rideId, after),
      });
      await event.data.after.ref.update({
        receiptSentAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      logger.info("receipt emailed", { rideId, email });
    } catch (e) {
      logger.error("receipt email failed", { rideId, msg: e?.message });
    }
  }
);
