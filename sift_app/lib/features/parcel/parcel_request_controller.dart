import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/parcel.dart';
import '../ride_request/services/directions_service.dart';

class ParcelRequestState {
  const ParcelRequestState({
    this.pickup,
    this.pickupAddress = 'Current location',
    this.stops = const [],
    this.routePoints = const [],
    this.distanceKm = 0,
  });

  final LatLng? pickup;
  final String pickupAddress;
  final List<ParcelStop> stops;
  final List<LatLng> routePoints;
  final double distanceKm;

  bool get ready => pickup != null && stops.isNotEmpty;

  ParcelRequestState copyWith({
    LatLng? pickup,
    String? pickupAddress,
    List<ParcelStop>? stops,
    List<LatLng>? routePoints,
    double? distanceKm,
  }) {
    return ParcelRequestState(
      pickup: pickup ?? this.pickup,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      stops: stops ?? this.stops,
      routePoints: routePoints ?? this.routePoints,
      distanceKm: distanceKm ?? this.distanceKm,
    );
  }
}

class ParcelRequestController extends Notifier<ParcelRequestState> {
  @override
  ParcelRequestState build() => const ParcelRequestState();

  Future<void> loadPickup() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      final here = LatLng(pos.latitude, pos.longitude);
      state = state.copyWith(pickup: here);
      final marks =
          await geo.placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (marks.isNotEmpty) {
        final m = marks.first;
        final line = [m.street, m.subLocality, m.locality]
            .where((s) => s != null && s.isNotEmpty)
            .join(', ');
        if (line.isNotEmpty) state = state.copyWith(pickupAddress: line);
      }
    } catch (_) {/* keep defaults */}
    await _recomputeRoute();
  }

  void setPickup(LatLng location, String address) {
    state = state.copyWith(pickup: location, pickupAddress: address);
    _recomputeRoute();
  }

  void addStop(ParcelStop stop) {
    state = state.copyWith(stops: [...state.stops, stop]);
    _recomputeRoute();
  }

  void updateStop(int index, ParcelStop stop) {
    final next = [...state.stops];
    if (index >= 0 && index < next.length) {
      next[index] = stop;
      state = state.copyWith(stops: next);
      _recomputeRoute();
    }
  }

  void removeStop(int index) {
    final next = [...state.stops]..removeAt(index);
    state = state.copyWith(stops: next);
    _recomputeRoute();
  }

  /// Sum the road legs pickup → stop1 → stop2 … for distance + a display line.
  Future<void> _recomputeRoute() async {
    final pickup = state.pickup;
    if (pickup == null || state.stops.isEmpty) {
      state = state.copyWith(distanceKm: 0, routePoints: const []);
      return;
    }
    final directions = ref.read(directionsServiceProvider);
    final points = <LatLng>[pickup];
    double distance = 0;
    var from = pickup;
    for (final stop in state.stops) {
      final leg = await directions.route(from, stop.location);
      if (leg != null) {
        distance += leg.distanceKm;
        if (leg.points.length >= 2) points.addAll(leg.points);
      }
      from = stop.location;
    }
    state = state.copyWith(
      distanceKm: double.parse(distance.toStringAsFixed(2)),
      routePoints: points,
    );
  }

  void reset() => state = const ParcelRequestState();
}

final parcelRequestProvider =
    NotifierProvider<ParcelRequestController, ParcelRequestState>(
  ParcelRequestController.new,
);
