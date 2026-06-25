import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'services/directions_service.dart';
import 'services/places_service.dart';

class RideRequestState {
  const RideRequestState({
    this.pickup,
    this.pickupAddress = 'Current location',
    this.destination,
    this.destinationLabel = '',
    this.route,
  });

  final LatLng? pickup;
  final String pickupAddress;
  final LatLng? destination;
  final String destinationLabel;
  final RouteResult? route;

  double get distanceKm => route?.distanceKm ?? 0;
  bool get hasRoute => route != null && route!.points.isNotEmpty;

  RideRequestState copyWith({
    LatLng? pickup,
    String? pickupAddress,
    LatLng? destination,
    String? destinationLabel,
    RouteResult? route,
  }) {
    return RideRequestState(
      pickup: pickup ?? this.pickup,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      destination: destination ?? this.destination,
      destinationLabel: destinationLabel ?? this.destinationLabel,
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

  /// Resolve a chosen destination to coordinates, then fetch the real route.
  Future<bool> chooseDestination(String placeId, String label) async {
    final dest = await ref.read(placesServiceProvider).placeLatLng(placeId);
    if (dest == null) return false;
    return chooseDestinationCoords(dest, label);
  }

  /// Set destination directly from coordinates (saved places) + fetch route.
  Future<bool> chooseDestinationCoords(LatLng dest, String label) async {
    state = state.copyWith(destination: dest, destinationLabel: label);
    final pickup = state.pickup;
    if (pickup != null) {
      final route = await ref.read(directionsServiceProvider).route(pickup, dest);
      if (route != null) state = state.copyWith(route: route);
    }
    return true;
  }

  void reset() => state = const RideRequestState();
}

final rideRequestProvider =
    NotifierProvider<RideRequestController, RideRequestState>(
  RideRequestController.new,
);
