import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A rider's saved place. [slot] is 'home' / 'work' for the pinned pair, or
/// null for extra custom places.
class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.label,
    required this.address,
    required this.latLng,
    this.slot,
  });

  final String id;
  final String label;
  final String address;
  final LatLng latLng;
  final String? slot;

  factory SavedPlace.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    return SavedPlace(
      id: doc.id,
      label: (m['label'] ?? '').toString(),
      address: (m['address'] ?? '').toString(),
      latLng: LatLng(
        (m['lat'] as num?)?.toDouble() ?? 0,
        (m['lng'] as num?)?.toDouble() ?? 0,
      ),
      slot: m['slot'] as String?,
    );
  }
}

/// Reads/writes `users/{uid}/places` — the rider's Home/Work + custom places.
class PlacesRepository {
  PlacesRepository({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _places(String uid) =>
      _db.collection('users').doc(uid).collection('places');

  /// Home first, then Work, then customs by label.
  Stream<List<SavedPlace>> watch(String uid) {
    return _places(uid).snapshots().map((s) {
      int rank(SavedPlace p) =>
          p.slot == 'home' ? 0 : (p.slot == 'work' ? 1 : 2);
      final list = s.docs.map(SavedPlace.fromDoc).toList()
        ..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : a.label.compareTo(b.label);
        });
      return list;
    });
  }

  /// Save a place. Slotted places (home/work) overwrite their slot.
  Future<void> save(
    String uid, {
    required String label,
    required String address,
    required LatLng latLng,
    String? slot,
  }) {
    final doc = slot != null ? _places(uid).doc(slot) : _places(uid).doc();
    return doc.set({
      'label': label,
      'address': address,
      'lat': latLng.latitude,
      'lng': latLng.longitude,
      'slot': slot,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> remove(String uid, String placeId) =>
      _places(uid).doc(placeId).delete();
}

final placesRepositoryProvider =
    Provider<PlacesRepository>((ref) => PlacesRepository());
