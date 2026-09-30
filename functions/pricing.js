/**
 * Server-authoritative pricing — the single source of truth for every money
 * value in Sift. Clients may *preview* fares for tier selection, but the
 * numbers that get charged and settled come from here, computed from the
 * admin-editable `config/pricing` document (with safe fallbacks baked in so
 * the app keeps working even if the doc is missing).
 *
 * All amounts are ZAR with 2-decimal rounding. Conversion to Paystack's
 * minor units (kobo/cents) happens at the Paystack boundary in P2, not here.
 */
const admin = require("firebase-admin");

/** Baked-in fallbacks — mirror the seeded `config/pricing` doc. */
const DEFAULTS = {
  fareBase: 30,
  farePerKm: 5,
  farePerMin: 0,
  tierMultipliers: { bike: 0.7, go: 1.0, xl: 1.45, max: 1.9 },
  commissionPct: 0.2,
  waitFreeMin: 5,
  waitPerMin: 1.5,
  cancelFee: 25,
  cashEnabled: true,
  cashDebtCapZar: 300,
  // City-wide surge multiplier applied when no zone covers the pickup.
  surgeMultiplier: 1.0,
  // How far (km) from the pickup we look for a driver to offer the ride to.
  dispatchRadiusKm: 20,
  minVersion: "1.0.0",
};

/** Clamp a surge multiplier to a sane range. */
const clampSurge = (n) => {
  const x = Number(n);
  if (!Number.isFinite(x) || x <= 0) return 1;
  return Math.min(5, Math.max(0.5, x));
};

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

/** Read pricing config, merged over defaults so partial docs are safe. */
async function readPricing() {
  try {
    const snap = await admin
      .firestore()
      .collection("config")
      .doc("pricing")
      .get();
    const data = snap.exists ? snap.data() : {};
    return {
      ...DEFAULTS,
      ...data,
      tierMultipliers: {
        ...DEFAULTS.tierMultipliers,
        ...(data.tierMultipliers || {}),
      },
    };
  } catch (_) {
    return { ...DEFAULTS };
  }
}

/** Quoted fare for a trip distance + tier, scaled by the surge multiplier. */
function computeFare(distanceKm, tierId, cfg, surge = 1) {
  const km = Math.max(0, Number(distanceKm) || 0);
  const mult = (cfg.tierMultipliers && cfg.tierMultipliers[tierId]) || 1;
  return round2((cfg.fareBase + cfg.farePerKm * km) * mult * clampSurge(surge));
}

/** Great-circle distance in km. */
function haversineKm(aLat, aLng, bLat, bLng) {
  const R = 6371;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const x =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

/** Active surge zones (circles) the admin manages from the dashboard. */
async function readZones() {
  try {
    const snap = await admin
      .firestore()
      .collection("zones")
      .where("active", "==", true)
      .get();
    return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
  } catch (_) {
    return [];
  }
}

/**
 * Surge multiplier for a pickup point: the first active zone whose circle
 * contains it wins; otherwise the city-wide `cfg.surgeMultiplier`.
 */
function surgeForPoint(lat, lng, zones, cfg) {
  if (typeof lat === "number" && typeof lng === "number") {
    for (const z of zones || []) {
      if (
        typeof z.lat === "number" &&
        typeof z.lng === "number" &&
        haversineKm(lat, lng, z.lat, z.lng) <= (Number(z.radiusKm) || 0)
      ) {
        return clampSurge(z.surgeMultiplier);
      }
    }
  }
  return clampSurge(cfg.surgeMultiplier ?? 1);
}

/**
 * Waiting fee: free for `waitFreeMin` after the driver marks arrived, then
 * `waitPerMin` per additional minute until the trip starts.
 */
function computeWaitFee(arrivedAt, startedAt, cfg) {
  if (!arrivedAt || !startedAt) return 0;
  const ms = startedAt.toMillis() - arrivedAt.toMillis();
  if (ms <= 0) return 0;
  const billableMin = Math.max(0, ms / 60000 - cfg.waitFreeMin);
  return round2(billableMin * cfg.waitPerMin);
}

/** Split a final fare into platform commission + driver earning. */
function splitFare(finalFare, cfg) {
  const fare = round2(finalFare);
  const commission = round2(fare * cfg.commissionPct);
  return { finalFare: fare, commission, driverEarning: round2(fare - commission) };
}

module.exports = {
  DEFAULTS,
  round2,
  clampSurge,
  readPricing,
  computeFare,
  computeWaitFee,
  splitFare,
  readZones,
  surgeForPoint,
};
