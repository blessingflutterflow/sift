import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The admin-managed fare model, read live from `config/pricing`.
///
/// The rider's *displayed* quote is a preview — the server recomputes the
/// authoritative fare at dispatch from this same doc, so preview and charge
/// stay in sync. Previously the preview used hardcoded constants, which is why
/// admin price changes never showed up in the app.
class PricingConfig {
  const PricingConfig({
    required this.fareBase,
    required this.farePerKm,
    required this.tierMultipliers,
  });

  final double fareBase;
  final double farePerKm;

  /// Per-tier multiplier overrides keyed by tier id (bike/go/xl/max). Empty =
  /// use each tier's built-in default.
  final Map<String, double> tierMultipliers;

  /// Multiplier for [tierId], falling back to the tier's own [fallback] when
  /// the admin config doesn't override it.
  double multiplierFor(String tierId, double fallback) =>
      tierMultipliers[tierId] ?? fallback;

  /// Baked-in defaults — mirror the server's `DEFAULTS` in pricing.js so the
  /// app quotes sensibly even before the config doc loads (or offline).
  static const PricingConfig fallback = PricingConfig(
    fareBase: 30,
    farePerKm: 5,
    tierMultipliers: {},
  );

  factory PricingConfig.fromMap(Map<String, dynamic>? d) {
    final m = d ?? const {};
    double n(dynamic v, double dflt) =>
        (v is num && v.isFinite && v >= 0) ? v.toDouble() : dflt;

    final tiers = <String, double>{};
    final raw = m['tierMultipliers'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is num && v.isFinite && v > 0) tiers[k.toString()] = v.toDouble();
      });
    }
    return PricingConfig(
      fareBase: n(m['fareBase'], fallback.fareBase),
      farePerKm: n(m['farePerKm'], fallback.farePerKm),
      tierMultipliers: tiers,
    );
  }
}

/// Live stream of the admin fare config. Updates the rider's quote within
/// seconds of an admin saving new pricing.
final pricingConfigProvider = StreamProvider<PricingConfig>((ref) {
  return FirebaseFirestore.instance
      .collection('config')
      .doc('pricing')
      .snapshots()
      .map((snap) => PricingConfig.fromMap(snap.data()));
});
