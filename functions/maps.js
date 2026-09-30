/**
 * Google Maps REST proxy — keeps the Directions/Places key out of the APK
 * (a key shipped in the binary can be extracted and abused; this one lives in
 * Secret Manager and is only callable by signed-in users).
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

const MAPS_API_KEY = defineSecret("MAPS_API_KEY");
const REGION = "europe-west1";

function requireAuth(req) {
  if (!req.auth?.uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
}

const isNum = (v) => typeof v === "number" && Number.isFinite(v);

/** Directions: origin → destination, optionally via ordered waypoints (stops).
 *  Returns the encoded overview polyline + total distance/duration across every
 *  leg, so a multi-stop trip is priced and drawn end-to-end. */
exports.getRoute = onCall(
  { region: REGION, secrets: [MAPS_API_KEY] },
  async (req) => {
    requireAuth(req);
    const { oLat, oLng, dLat, dLng, waypoints } = req.data || {};
    if (![oLat, oLng, dLat, dLng].every(isNum)) {
      throw new HttpsError("invalid-argument", "origin/destination required.");
    }
    // Ordered stops between origin and destination → &waypoints=lat,lng|lat,lng
    let wpParam = "";
    if (Array.isArray(waypoints) && waypoints.length) {
      const parts = waypoints
        .filter((w) => w && isNum(w.lat) && isNum(w.lng))
        .map((w) => `${w.lat},${w.lng}`);
      if (parts.length) wpParam = `&waypoints=${parts.join("|")}`;
    }
    const url =
      `https://maps.googleapis.com/maps/api/directions/json` +
      `?origin=${oLat},${oLng}&destination=${dLat},${dLng}` +
      wpParam +
      `&key=${MAPS_API_KEY.value()}`;
    try {
      const res = await fetch(url);
      const data = await res.json();
      const route = data.routes?.[0];
      const legs = route?.legs || [];
      if (!route || !legs.length) return { points: null };
      // Sum every leg so distance/duration cover the whole multi-stop route.
      const meters = legs.reduce((a, l) => a + (l.distance?.value ?? 0), 0);
      const seconds = legs.reduce((a, l) => a + (l.duration?.value ?? 0), 0);
      return {
        points: route.overview_polyline?.points ?? null,
        distanceKm: meters / 1000,
        durationMin: Math.round(seconds / 60),
      };
    } catch (e) {
      logger.warn("getRoute failed", e?.message);
      throw new HttpsError("internal", "Routing unavailable.");
    }
  }
);

/** Places autocomplete, biased to South Africa. */
exports.placesAutocomplete = onCall(
  { region: REGION, secrets: [MAPS_API_KEY] },
  async (req) => {
    requireAuth(req);
    const input = String(req.data?.input ?? "").trim();
    if (input.length < 2) return { predictions: [] };
    const url =
      `https://maps.googleapis.com/maps/api/place/autocomplete/json` +
      `?input=${encodeURIComponent(input)}&components=country:za` +
      `&key=${MAPS_API_KEY.value()}`;
    try {
      const res = await fetch(url);
      const data = await res.json();
      return {
        predictions: (data.predictions ?? []).map((p) => ({
          placeId: p.place_id,
          primary: p.structured_formatting?.main_text ?? p.description ?? "",
          secondary: p.structured_formatting?.secondary_text ?? "",
        })),
      };
    } catch (e) {
      logger.warn("placesAutocomplete failed", e?.message);
      return { predictions: [] };
    }
  }
);

/** Resolve a place to coordinates. */
exports.placeDetails = onCall(
  { region: REGION, secrets: [MAPS_API_KEY] },
  async (req) => {
    requireAuth(req);
    const placeId = String(req.data?.placeId ?? "");
    if (!placeId) throw new HttpsError("invalid-argument", "placeId required.");
    const url =
      `https://maps.googleapis.com/maps/api/place/details/json` +
      `?place_id=${encodeURIComponent(placeId)}&fields=geometry` +
      `&key=${MAPS_API_KEY.value()}`;
    try {
      const res = await fetch(url);
      const data = await res.json();
      const loc = data.result?.geometry?.location;
      if (!loc) return { lat: null, lng: null };
      return { lat: loc.lat, lng: loc.lng };
    } catch (e) {
      logger.warn("placeDetails failed", e?.message);
      throw new HttpsError("internal", "Place lookup unavailable.");
    }
  }
);
