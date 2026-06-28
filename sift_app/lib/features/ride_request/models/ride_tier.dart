import 'package:flutter/material.dart';

import '../../../core/config.dart';

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
  });

  final String id;
  final String name;
  final int etaMin;
  final int seats;
  final double multiplier;
  final IconData icon; // placeholder until car PNGs land
  final IconData? badge;
  final bool range; // show a price range (e.g. Black Cab)

  /// Numeric fare for a trip distance (ZAR).
  double fareValue(double distanceKm) =>
      (AppConfig.fareBase + AppConfig.farePerKm * distanceKm) * multiplier;

  /// Fare for a given trip distance, e.g. "R76" or "R185–278".
  String price(double distanceKm) {
    final fare = (AppConfig.fareBase + AppConfig.farePerKm * distanceKm) *
        multiplier;
    if (range) {
      final low = fare * 0.85;
      final high = fare * 1.15;
      return 'R${low.round()}–${high.round()}';
    }
    return 'R${fare.toStringAsFixed(0)}';
  }
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
    seats: 4,
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
  ),
  RideTier(
    id: 'max',
    name: 'Sift Max',
    etaMin: 8,
    seats: 7,
    multiplier: 1.9,
    icon: Icons.directions_bus_filled,
  ),
];
