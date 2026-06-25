import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ride.dart';

/// Client side of the ride contract. Riders create a request and listen;
/// drivers watch offers made to them. The dispatch-critical actions
/// (accept/decline/cancel) go through Cloud Functions so the server stays
/// authoritative — clients never flip status directly for those.
class RideRepository {
  RideRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _functions = functions ??
            FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> get _rides =>
      _db.collection('rides');

  static const _activeStatuses = [
    'requested',
    'accepted',
    'arriving',
    'arrived',
    'in_progress',
  ];

  /// Rider creates a request (server then orchestrates dispatch).
  Future<String> createRequest(Map<String, dynamic> data) async {
    final doc = await _rides.add(data);
    return doc.id;
  }

  Stream<Ride> watch(String rideId) =>
      _rides.doc(rideId).snapshots().map(Ride.fromDoc);

  /// Rides currently offered to this driver (0 or 1 in practice).
  Stream<List<Ride>> watchOffersFor(String driverId) {
    return _rides
        .where('offeredTo', isEqualTo: driverId)
        .snapshots()
        .map((s) => s.docs.map(Ride.fromDoc).toList());
  }

  /// The driver's currently-accepted ride (for resuming a trip).
  Stream<List<Ride>> watchDriverActive(String driverId) {
    return _rides
        .where('driverId', isEqualTo: driverId)
        .where('status', whereIn: ['accepted', 'arriving', 'arrived', 'in_progress'])
        .snapshots()
        .map((s) => s.docs.map(Ride.fromDoc).toList());
  }

  /// Past rides, newest first (history + receipts).
  Stream<List<Ride>> historyForRider(String riderId) {
    return _rides
        .where('riderId', isEqualTo: riderId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(Ride.fromDoc).toList());
  }

  Stream<List<Ride>> historyForDriver(String driverId) {
    return _rides
        .where('driverId', isEqualTo: driverId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(Ride.fromDoc).toList());
  }

  /// Upcoming scheduled (advance-booked) rides for a rider, soonest first.
  Stream<List<Ride>> watchScheduled(String riderId) {
    return _rides
        .where('riderId', isEqualTo: riderId)
        .where('status', isEqualTo: RideStatus.scheduled.value)
        .snapshots()
        .map((s) {
      final list = s.docs.map(Ride.fromDoc).toList()
        ..sort((a, b) => (a.scheduledFor ?? DateTime.now())
            .compareTo(b.scheduledFor ?? DateTime.now()));
      return list;
    });
  }

  /// Existing active ride for a rider — used to block duplicates.
  Future<Ride?> activeRideForRider(String riderId) async {
    final snap = await _rides
        .where('riderId', isEqualTo: riderId)
        .where('status', whereIn: _activeStatuses)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return Ride.fromDoc(snap.docs.first);
  }

  // --- Server-authoritative actions (Cloud Functions) ---
  Future<void> accept(String rideId) =>
      _call('acceptRide', {'rideId': rideId});

  Future<void> decline(String rideId) =>
      _call('declineRide', {'rideId': rideId});

  Future<void> cancel(String rideId) =>
      _call('cancelRide', {'rideId': rideId});

  /// Trip completion is server-authoritative: it computes the final fare,
  /// commission and ledger — the client never writes `completed` directly.
  Future<void> complete(String rideId) =>
      _call('completeRide', {'rideId': rideId});

  Future<void> _call(String name, Map<String, dynamic> data) async {
    await _functions.httpsCallable(name).call(data);
  }

  /// Driver-side trip status (allowed by rules for the assigned driver).
  /// Milestones are server-stamped so countdowns survive app restarts.
  Future<void> setStatus(String rideId, RideStatus status) {
    final data = <String, dynamic>{'status': status.value};
    if (status == RideStatus.arrived) {
      data['arrivedAt'] = FieldValue.serverTimestamp();
    } else if (status == RideStatus.inProgress) {
      data['startedAt'] = FieldValue.serverTimestamp();
    } else if (status == RideStatus.completed) {
      data['completedAt'] = FieldValue.serverTimestamp();
    }
    return _rides.doc(rideId).update(data);
  }

  /// Driver's live telemetry, mirrored into the ride doc for the rider.
  /// Fire-and-forget — a dropped sample is fine, the next one supersedes it.
  Future<void> updateDriverTelemetry(
    String rideId, {
    required double lat,
    required double lng,
    double? heading,
    double? speedKmh,
  }) {
    return _rides.doc(rideId).update({
      'driverLat': lat,
      'driverLng': lng,
      'driverHeading': ?heading,
      'driverSpeedKmh': ?speedKmh,
      'driverUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> rateAsRider(String rideId, int stars) =>
      _rides.doc(rideId).update({'riderRating': stars});

  Future<void> rateAsDriver(String rideId, int stars) =>
      _rides.doc(rideId).update({'driverRating': stars});
}

final rideRepositoryProvider =
    Provider<RideRepository>((ref) => RideRepository());
