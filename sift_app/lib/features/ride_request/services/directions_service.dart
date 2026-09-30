import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteResult {
  const RouteResult({
    required this.points,
    required this.distanceKm,
    required this.durationMin,
  });
  final List<LatLng> points;
  final double distanceKm;
  final int durationMin;
}

/// Routing via the `getRoute` Cloud Function — the Maps key never ships in
/// the APK. The encoded polyline is decoded client-side.
class DirectionsService {
  DirectionsService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFunctions _functions;

  Future<RouteResult?> route(
    LatLng origin,
    LatLng destination, {
    List<LatLng> waypoints = const [],
  }) async {
    try {
      final res = await _functions
          .httpsCallable('getRoute')
          .call<Map<dynamic, dynamic>>({
        'oLat': origin.latitude,
        'oLng': origin.longitude,
        'dLat': destination.latitude,
        'dLng': destination.longitude,
        if (waypoints.isNotEmpty)
          'waypoints': waypoints
              .map((w) => {'lat': w.latitude, 'lng': w.longitude})
              .toList(),
      });
      final encoded = res.data['points'] as String?;
      if (encoded == null || encoded.isEmpty) return null;
      final points = PolylinePoints.decodePolyline(encoded)
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();
      return RouteResult(
        points: points,
        distanceKm: (res.data['distanceKm'] as num?)?.toDouble() ?? 0,
        durationMin: (res.data['durationMin'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null; // callers fall back to straight-line tracking
    }
  }
}

final directionsServiceProvider =
    Provider<DirectionsService>((ref) => DirectionsService());
