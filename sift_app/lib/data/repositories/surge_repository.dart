import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads the admin-managed surge config so the rider can preview the surge
/// multiplier for their pickup before requesting. The authoritative fare is
/// still computed server-side at dispatch — this mirrors that logic for the UI.
class SurgeRepository {
  SurgeRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static double _clamp(num? n) {
    final x = (n ?? 1).toDouble();
    if (!x.isFinite || x <= 0) return 1;
    return x.clamp(0.5, 5.0);
  }

  static double _haversineKm(
      double aLat, double aLng, double bLat, double bLng) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(bLat - aLat);
    final dLng = rad(bLng - aLng);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(aLat)) *
            math.cos(rad(bLat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  /// Surge multiplier for a pickup: first active zone containing it wins, else
  /// the city-wide `config/pricing.surgeMultiplier`, else 1.0.
  Future<double> surgeForPoint(double lat, double lng) async {
    try {
      final results = await Future.wait([
        _db.collection('zones').where('active', isEqualTo: true).get(),
        _db.collection('config').doc('pricing').get(),
      ]);
      final zones = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final cfg = results[1] as DocumentSnapshot<Map<String, dynamic>>;

      for (final z in zones.docs) {
        final m = z.data();
        final zLat = (m['lat'] as num?)?.toDouble();
        final zLng = (m['lng'] as num?)?.toDouble();
        final radiusKm = (m['radiusKm'] as num?)?.toDouble() ?? 0;
        if (zLat != null &&
            zLng != null &&
            _haversineKm(lat, lng, zLat, zLng) <= radiusKm) {
          return _clamp(m['surgeMultiplier'] as num?);
        }
      }
      return _clamp(cfg.data()?['surgeMultiplier'] as num?);
    } catch (_) {
      return 1.0;
    }
  }
}

final surgeRepositoryProvider =
    Provider<SurgeRepository>((ref) => SurgeRepository());
