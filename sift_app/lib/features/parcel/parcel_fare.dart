import '../../data/models/parcel.dart';

/// Client-side parcel fare preview. Mirrors functions/parcelPricing.js — the
/// server recomputes the authoritative number from config/parcelPricing.
class ParcelFare {
  ParcelFare._();

  static const double base = 25; // collection fee
  static const double perKm = 6;
  static const double perStop = 10;
  static const Map<String, double> sizeSurcharge = {
    'small': 0,
    'medium': 15,
    'large': 35,
  };

  static double estimate(double distanceKm, List<ParcelStop> stops) {
    final km = distanceKm < 0 ? 0.0 : distanceKm;
    var total = base + perKm * km;
    for (final s in stops) {
      total += perStop + (sizeSurcharge[s.size] ?? 0);
    }
    return total;
  }
}
