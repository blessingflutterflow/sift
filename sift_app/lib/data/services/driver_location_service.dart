import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Location settings for driver streams. On Android this attaches a
/// foreground-service notification so GPS keeps flowing with the screen off
/// or the app backgrounded — without it, tracking dies the moment the driver
/// pockets their phone.
LocationSettings driverLocationSettings({
  required int distanceFilter,
  required String notificationText,
}) {
  if (!kIsWeb && Platform.isAndroid) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilter,
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: 'Sift — you\'re online',
        notificationText: notificationText,
        notificationIcon:
            const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        enableWakeLock: true,
      ),
    );
  }
  return LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: distanceFilter,
  );
}

/// Streams the driver's GPS to `driver_locations/{uid}` while they're online,
/// so the admin dashboard can show them live. Stops + marks offline on demand.
class DriverLocationService {
  DriverLocationService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  StreamSubscription<Position>? _sub;
  DateTime _lastWriteAt = DateTime.fromMillisecondsSinceEpoch(0);

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('driver_locations').doc(uid);

  Future<void> goOnline({
    required String uid,
    required String name,
    String? vehicle,
  }) async {
    await _sub?.cancel();

    Future<void> write(Position p) => _doc(uid).set({
          'uid': uid,
          'name': name,
          'vehicle': vehicle,
          'lat': p.latitude,
          'lng': p.longitude,
          'online': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    // Immediate fix, then stream updates.
    try {
      write(await Geolocator.getCurrentPosition());
    } catch (_) {}

    _sub = Geolocator.getPositionStream(
      locationSettings: driverLocationSettings(
        distanceFilter: 8,
        notificationText: 'Receiving ride requests',
      ),
    ).listen((p) {
      // The admin map doesn't need sub-second fidelity — cap writes to ~1/4s
      // so a moving car doesn't hammer Firestore.
      final now = DateTime.now();
      if (now.difference(_lastWriteAt).inSeconds < 4) return;
      _lastWriteAt = now;
      write(p);
    });
  }

  Future<void> goOffline(String uid) async {
    await _sub?.cancel();
    _sub = null;
    await _doc(uid).set({
      'online': false,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}

final driverLocationServiceProvider =
    Provider<DriverLocationService>((ref) => DriverLocationService());
