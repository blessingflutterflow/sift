import 'package:flutter/material.dart';

import 'pricing_config.dart';

/// A selectable ride tier. [multiplier] scales the base fare; [badge] is an
/// optional small green accent (electric ⚡, pet 🐾).
class RideTier {
  const RideTier({
    required this.id,
    required this.name,
    required this.etaMin,
    required this.seats,
    required this.multiplier,
    required this.icon,
    this.badge,
    this.range = false,
    this.seatsText,
  });

  final String id;
  final String name;
  final int etaMin;
  final int seats;
  final double multiplier;
  final IconData icon; // placeholder until car PNGs land
  final IconData? badge;
  final bool range; // show a price range (e.g. Black Cab)

  /// Optional override for the seat label (e.g. a "4–7 seats" range).
  final String? seatsText;

  /// What to show under the tier name for seating.
  String get seatsLabel =>
      seatsText ?? '$seats seat${seats == 1 ? '' : 's'}';

  /// Numeric fare for a trip distance (ZAR), computed from the live admin
  /// pricing config so it reflects any base/per-km/multiplier changes.
  double fareValue(double distanceKm, PricingConfig cfg) =>
      (cfg.fareBase + cfg.farePerKm * distanceKm) *
      cfg.multiplierFor(id, multiplier);
}

/// Tiers, scaling up by passenger capacity. (These will become
/// admin-configurable from Firestore later.) Icons stand in until the
/// matching `assets/cars/{id}.png` art is added.
const List<RideTier> kRideTiers = [
  RideTier(
    id: 'bike',
    name: 'Sift Bike',
    etaMin: 2,
    seats: 1,
    multiplier: 0.7,
    icon: Icons.two_wheeler,
  ),
  RideTier(
    id: 'go',
    name: 'Sift Go',
    etaMin: 3,
    seats: 2,
    multiplier: 1.0,
    icon: Icons.directions_car,
  ),
  RideTier(
    id: 'xl',
    name: 'Sift XL',
    etaMin: 5,
    seats: 6,
    multiplier: 1.45,
    icon: Icons.airport_shuttle,
    seatsText: '4–7 seats',
  ),
  RideTier(
    // id stays 'max' so pricing/data are unchanged; display name only.
    id: 'max',
    name: 'Sift Premium',
    etaMin: 8,
    seats: 7,
    multiplier: 1.9,
    icon: Icons.directions_bus_filled,
  ),
];
