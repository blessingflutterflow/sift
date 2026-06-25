import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../ride_request/services/directions_service.dart';

/// One snapshot of progress along the active route.
class RouteProgress {
  const RouteProgress({
    required this.snapped,
    required this.remainingPath,
    required this.remainingKm,
    required this.etaMin,
    required this.headingDeg,
    required this.offRoute,
  });

  /// The position projected onto the route — cars ride the road, not raw GPS.
  final LatLng snapped;

  /// Polyline from [snapped] to the end — the line shrinks as the car moves.
  final List<LatLng> remainingPath;

  final double remainingKm;

  /// Live ETA, recalibrated on every update (not just on Directions fetches).
  final int etaMin;

  /// Direction of travel along the current route segment. Rotating the car
  /// marker by this (instead of raw GPS heading) keeps it aligned to streets.
  final double headingDeg;

  /// True when the vehicle has persistently left the route — refetch time.
  final bool offRoute;
}

/// Tracks live progress along a Directions route entirely client-side.
///
/// Given the route polyline once, every GPS fix is projected onto it to get a
/// snapped position, consumed/remaining path, road-aligned heading and a fresh
/// ETA — so the Directions API is only re-queried when the vehicle actually
/// leaves the route (or the route grows stale), not on a movement timer.
class RouteTracker {
  static const double _offRouteMeters = 55;
  static const int _offRouteStrikes = 3;
  static const Duration _staleAfter = Duration(seconds: 90);

  List<LatLng> _path = const [];
  List<double> _cumMeters = const [];
  double _totalMeters = 0;
  double _avgKmh = 24;
  DateTime? _fetchedAt;
  int _strikes = 0;
  bool _offRoute = false;

  bool get hasRoute => _path.length >= 2;

  /// Whether the caller should fetch Directions (no route, off-route, stale).
  bool get needsRoute {
    if (!hasRoute || _offRoute) return true;
    final at = _fetchedAt;
    return at == null || DateTime.now().difference(at) > _staleAfter;
  }

  /// Drop the current route (e.g. the target flipped pickup → destination).
  void clear() {
    _path = const [];
    _cumMeters = const [];
    _totalMeters = 0;
    _fetchedAt = null;
    _strikes = 0;
    _offRoute = false;
  }

  /// Install a freshly fetched route and precompute cumulative distances.
  void setRoute(RouteResult route) {
    final pts = route.points;
    if (pts.length < 2) return;
    _path = List.of(pts);
    final cum = List<double>.filled(_path.length, 0);
    var total = 0.0;
    for (var i = 1; i < _path.length; i++) {
      total += metersBetween(_path[i - 1], _path[i]);
      cum[i] = total;
    }
    _cumMeters = cum;
    _totalMeters = total;
    // Average road speed implied by the route itself — the ETA baseline.
    if (route.durationMin > 0) {
      _avgKmh =
          ((total / 1000) / (route.durationMin / 60)).clamp(10.0, 100.0);
    }
    _fetchedAt = DateTime.now();
    _strikes = 0;
    _offRoute = false;
  }

  /// Project [pos] onto the route. Returns null when no route is loaded.
  /// [speedKmh] (live GPS speed) blends into the ETA when meaningful.
  RouteProgress? update(LatLng pos, {double? speedKmh}) {
    if (!hasRoute) return null;

    // Closest point across all segments (equirectangular projection — fine
    // at street scale).
    final cosLat = math.cos(pos.latitude * math.pi / 180);
    var bestSeg = 0;
    var bestT = 0.0;
    var bestPerp = double.infinity;
    for (var i = 0; i < _path.length - 1; i++) {
      final a = _path[i];
      final b = _path[i + 1];
      final abx = (b.longitude - a.longitude) * 111320 * cosLat;
      final aby = (b.latitude - a.latitude) * 110540;
      final apx = (pos.longitude - a.longitude) * 111320 * cosLat;
      final apy = (pos.latitude - a.latitude) * 110540;
      final len2 = abx * abx + aby * aby;
      final t = len2 == 0 ? 0.0 : ((apx * abx + apy * aby) / len2).clamp(0.0, 1.0);
      final dx = apx - abx * t;
      final dy = apy - aby * t;
      final perp = math.sqrt(dx * dx + dy * dy);
      if (perp < bestPerp) {
        bestPerp = perp;
        bestSeg = i;
        bestT = t;
      }
    }

    // Off-route needs persistence — one noisy fix shouldn't trigger a refetch.
    if (bestPerp > _offRouteMeters) {
      _strikes++;
      if (_strikes >= _offRouteStrikes) _offRoute = true;
    } else {
      _strikes = 0;
    }

    final a = _path[bestSeg];
    final b = _path[bestSeg + 1];
    final snapped = LatLng(
      a.latitude + (b.latitude - a.latitude) * bestT,
      a.longitude + (b.longitude - a.longitude) * bestT,
    );

    final segMeters = _cumMeters[bestSeg + 1] - _cumMeters[bestSeg];
    final traveled = _cumMeters[bestSeg] + segMeters * bestT;
    final remaining = math.max(0.0, _totalMeters - traveled);

    final remainingPath = <LatLng>[snapped, ..._path.sublist(bestSeg + 1)];

    // Heading along the road. On a degenerate (zero-length) segment fall back
    // to the next one so the car never spins to 0°.
    var heading = bearingBetween(a, b);
    if (segMeters < 1 && bestSeg + 2 < _path.length) {
      heading = bearingBetween(b, _path[bestSeg + 2]);
    }

    // ETA: route's own average speed, blended with live speed when the car is
    // actually moving (slow traffic drags the ETA up, open road pulls it down).
    var kmh = _avgKmh;
    if (speedKmh != null && speedKmh.isFinite && speedKmh > 6) {
      kmh = _avgKmh * 0.55 + speedKmh * 0.45;
    }
    final etaMin = remaining < 40
        ? 0
        : ((remaining / 1000) / kmh * 60).ceil().clamp(1, 180);

    return RouteProgress(
      snapped: snapped,
      remainingPath: remainingPath,
      remainingKm: remaining / 1000,
      etaMin: etaMin,
      headingDeg: heading,
      offRoute: _offRoute,
    );
  }

  /// A straight-line stand-in when Directions is unavailable, so tracking and
  /// ETA still work (~28 km/h urban assumption).
  static RouteResult fallbackRoute(LatLng from, LatLng to) {
    final km = metersBetween(from, to) / 1000;
    return RouteResult(
      points: [from, to],
      distanceKm: km,
      durationMin: (km / 28 * 60).ceil().clamp(1, 180),
    );
  }

  // --- Shared geo math (single home for the formulas screens used to copy) ---

  static double metersBetween(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(x));
  }

  static double bearingBetween(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}
