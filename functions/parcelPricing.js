/**
 * Server-authoritative parcel pricing. Fare = collection base + per-km over the
 * multi-stop route + a per-drop-off fee + a size surcharge per parcel. Admin
 * edits `config/parcelPricing` live; safe fallbacks baked in.
 *
 * All amounts ZAR, 2-decimal rounding. Mirrors pricing.js for ride fares.
 */
const admin = require("firebase-admin");
const { round2, splitFare } = require("./pricing");

const DEFAULTS = {
  base: 25, // collection fee
  perKm: 6, // over the whole pickup → drop-offs route
  perStop: 10, // per drop-off
  sizeSurcharge: { small: 0, medium: 15, large: 35 },
  commissionPct: 0.2,
  cancelFee: 20,
};

async function readParcelPricing() {
  try {
    const snap = await admin
      .firestore()
      .collection("config")
      .doc("parcelPricing")
      .get();
    const data = snap.exists ? snap.data() : {};
    return {
      ...DEFAULTS,
      ...data,
      sizeSurcharge: {
        ...DEFAULTS.sizeSurcharge,
        ...(data.sizeSurcharge || {}),
      },
    };
  } catch (_) {
    return { ...DEFAULTS };
  }
}

/** Quoted fare for a parcel: base + distance + per-stop + size surcharges. */
function computeParcelFare(distanceKm, stops, cfg) {
  const km = Math.max(0, Number(distanceKm) || 0);
  let total = cfg.base + cfg.perKm * km;
  for (const s of stops || []) {
    const size = (s && s.size) || "small";
    total += cfg.perStop + (cfg.sizeSurcharge[size] || 0);
  }
  return round2(total);
}

module.exports = {
  DEFAULTS,
  readParcelPricing,
  computeParcelFare,
  splitFare,
};
