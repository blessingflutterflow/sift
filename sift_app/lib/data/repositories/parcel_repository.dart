import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/parcel.dart';

/// Client side of the parcel contract. Senders create a request and listen;
/// drivers watch offers. Dispatch-critical + money actions go through Cloud
/// Functions so the server stays authoritative.
class ParcelRepository {
  ParcelRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _functions = functions ??
            FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> get _parcels =>
      _db.collection('parcels');

  static const _activeStatuses = [
    'requested',
    'accepted',
    'arriving',
    'picked_up',
    'delivering',
  ];

  Future<String> createRequest(Map<String, dynamic> data) async {
    final doc = await _parcels.add(data);
    return doc.id;
  }

  Stream<Parcel> watch(String parcelId) =>
      _parcels.doc(parcelId).snapshots().map(Parcel.fromDoc);

  Stream<List<Parcel>> watchOffersFor(String driverId) {
    return _parcels
        .where('offeredTo', isEqualTo: driverId)
        .snapshots()
        .map((s) => s.docs.map(Parcel.fromDoc).toList());
  }

  Stream<List<Parcel>> watchDriverActive(String driverId) {
    return _parcels
        .where('driverId', isEqualTo: driverId)
        .where('status',
            whereIn: ['accepted', 'arriving', 'picked_up', 'delivering'])
        .snapshots()
        .map((s) => s.docs.map(Parcel.fromDoc).toList());
  }

  Stream<List<Parcel>> historyForSender(String senderId) {
    return _parcels
        .where('senderId', isEqualTo: senderId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(Parcel.fromDoc).toList());
  }

  Future<Parcel?> activeParcelForSender(String senderId) async {
    final snap = await _parcels
        .where('senderId', isEqualTo: senderId)
        .where('status', whereIn: _activeStatuses)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return Parcel.fromDoc(snap.docs.first);
  }

  // --- Server-authoritative actions (Cloud Functions) ---
  Future<void> accept(String parcelId) =>
      _call('acceptParcel', {'parcelId': parcelId});

  Future<void> decline(String parcelId) =>
      _call('declineParcel', {'parcelId': parcelId});

  Future<void> cancel(String parcelId) =>
      _call('cancelParcel', {'parcelId': parcelId});

  /// Driver marks the parcel collected from the sender.
  Future<void> markPickedUp(String parcelId) =>
      _call('pickUpParcel', {'parcelId': parcelId});

  /// Deliver a drop-off with proof (photo + signature URLs already uploaded).
  Future<void> deliverStop(
    String parcelId,
    int stopIndex, {
    required String podPhotoUrl,
    required String podSignatureUrl,
    required String receivedBy,
  }) =>
      _call('deliverParcelStop', {
        'parcelId': parcelId,
        'stopIndex': stopIndex,
        'podPhotoUrl': podPhotoUrl,
        'podSignatureUrl': podSignatureUrl,
        'receivedBy': receivedBy,
      });

  /// Mark a drop-off failed (recipient unavailable, wrong address, etc.).
  Future<void> failStop(String parcelId, int stopIndex, String reason) =>
      _call('failParcelStop', {
        'parcelId': parcelId,
        'stopIndex': stopIndex,
        'reason': reason,
      });

  /// Settle the parcel once every stop is resolved (server computes money).
  Future<void> complete(String parcelId) =>
      _call('completeParcel', {'parcelId': parcelId});

  /// Driver's live telemetry, mirrored into the parcel doc for the sender.
  Future<void> updateDriverTelemetry(
    String parcelId, {
    required double lat,
    required double lng,
    double? heading,
  }) {
    return _parcels.doc(parcelId).update({
      'driverLat': lat,
      'driverLng': lng,
      'driverHeading': ?heading,
      'driverUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _call(String name, Map<String, dynamic> data) async {
    await _functions.httpsCallable(name).call(data);
  }
}

final parcelRepositoryProvider =
    Provider<ParcelRepository>((ref) => ParcelRepository());
