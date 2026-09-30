import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/ride.dart';
import 'services/directions_service.dart';
import 'services/places_service.dart';

/// Max intermediate stops a rider can add between pickup and destination.
const int kMaxRideStops = 3;

class RideRequestState {
  const RideRequestState({
    this.pickup,
    this.pickupAddress = 'Current location',
    this.destination,
    this.destinationLabel = '',
    this.stops = const [],
    this.route,
  });

  final LatLng? pickup;
  final String pickupAddress;
  final LatLng? destination;
  final String destinationLabel;

  /// Intermediate stops between pickup and destination.
  final List<RideStop> stops;
  final RouteResult? route;

  double get distanceKm => route?.distanceKm ?? 0;
  bool get hasRoute => route != null && route!.points.isNotEmpty;
  bool get canAddStop => stops.length < kMaxRideStops;

  RideRequestState copyWith({
    LatLng? pickup,
    String? pickupAddress,
    LatLng? destination,
    String? destinationLabel,
    List<RideStop>? stops,
    RouteResult? route,
  }) {
    return RideRequestState(
      pickup: pickup ?? this.pickup,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      destination: destination ?? this.destination,
      destinationLabel: destinationLabel ?? this.destinationLabel,
      stops: stops ?? this.stops,
      route: route ?? this.route,
    );
  }
}

class RideRequestController extends Notifier<RideRequestState> {
  @override
  RideRequestState build() => const RideRequestState();

  /// Get the device location and reverse-geocode it for the pickup label.
  Future<void> loadPickup() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      final here = LatLng(pos.latitude, pos.longitude);
      state = state.copyWith(pickup: here);

      final marks = await geo.placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (marks.isNotEmpty) {
        final m = marks.first;
        final line = [m.street, m.subLocality, m.locality]
            .where((s) => s != null && s.isNotEmpty)
            .join(', ');
        if (line.isNotEmpty) {
          state = state.copyWith(pickupAddress: line);
        }
      }
    } catch (_) {
      // Keep defaults if location/geocoding unavailable.
    }
  }

  /// Recompute the route across the whole trip: pickup → stops → destination.
  Future<void> _recompute() async {
    final pickup = state.pickup;
    final dest = state.destination;
    if (pickup == null || dest == null) return;
    final route = await ref.read(directionsServiceProvider).route(
          pickup,
          dest,
          waypoints: state.stops.map((s) => s.latLng).toList(),
        );
    if (route != null) state = state.copyWith(route: route);
  }

  /// Resolve a chosen destination to coordinates, then fetch the real route.
  Future<bool> chooseDestination(String placeId, String label) async {
    final dest = await ref.read(placesServiceProvider).placeLatLng(placeId);
    if (dest == null) return false;
    return chooseDestinationCoords(dest, label);
  }

  /// Set destination directly from coordinates (saved places) + fetch route.
  Future<bool> chooseDestinationCoords(LatLng dest, String label) async {
    state = state.copyWith(destination: dest, destinationLabel: label);
    await _recompute();
    return true;
  }

  /// Rider typed a pickup instead of using GPS — resolve + set it, and refresh
  /// the route if a destination is already chosen.
  Future<bool> choosePickup(String placeId, String label) async {
    final coords = await ref.read(placesServiceProvider).placeLatLng(placeId);
    if (coords == null) return false;
    return choosePickupCoords(coords, label);
  }

  /// Set pickup directly from coordinates (+ refresh the route if we can).
  Future<bool> choosePickupCoords(LatLng coords, String label) async {
    state = state.copyWith(pickup: coords, pickupAddress: label);
    await _recompute();
    return true;
  }

  /// Add an intermediate stop by place id, then refresh the route.
  Future<bool> addStop(String placeId, String label) async {
    if (!state.canAddStop) return false;
    final coords = await ref.read(placesServiceProvider).placeLatLng(placeId);
    if (coords == null) return false;
    return addStopCoords(coords, label);
  }

  /// Add an intermediate stop from coordinates, then refresh the route.
  Future<bool> addStopCoords(LatLng coords, String label) async {
    if (!state.canAddStop) return false;
    state = state.copyWith(stops: [...state.stops, RideStop(coords, label)]);
    await _recompute();
    return true;
  }

  /// Remove the intermediate stop at [index], then refresh the route.
  Future<void> removeStop(int index) async {
    if (index < 0 || index >= state.stops.length) return;
    final next = [...state.stops]..removeAt(index);
    state = state.copyWith(stops: next);
    await _recompute();
  }

  void reset() => state = const RideRequestState();
}

final rideRequestProvider =
    NotifierProvider<RideRequestController, RideRequestState>(
  RideRequestController.new,
);
