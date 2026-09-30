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
  Timer? _heartbeat;
  Position? _lastPos;
  DateTime _lastWriteAt = DateTime.fromMillisecondsSinceEpoch(0);

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('driver_locations').doc(uid);

  /// Start sharing the driver's location and mark them online. Returns true
  /// only if a position was actually written — i.e. the driver is genuinely
  /// dispatchable. Returns false when no location could be obtained (GPS off /
  /// permission denied / no fix), so the caller can tell the driver instead of
  /// leaving them "online" but invisible to dispatch.
  Future<bool> goOnline({
    required String uid,
    required String name,
    String? vehicle,
    String? category,
  }) async {
    await _sub?.cancel();

    // Safety net: never attempt a fix without GPS + permission. The driver-home
    // UI establishes both before calling this, but guarding here means a stray
    // call fails fast (false) instead of hanging on an 8s timeout and leaving a
    // driver "online" with no location behind them.
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }

    Future<void> write(Position p) => _doc(uid).set({
          'uid': uid,
          'name': name,
          'vehicle': vehicle,
          // Admin-assigned category (bike/go/xl/max/parcel) — dispatch matches
          // requests to it. Null/absent = eligible for everything.
          'category': category,
          'lat': p.latitude,
          'lng': p.longitude,
          'online': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    // Get an initial fix robustly: a fresh high-accuracy read with a timeout,
    // falling back to the last known position so a stationary device (or one
    // that's slow to lock GPS) still goes online immediately.
    Position? first;
    try {
      first = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      try {
        first = await Geolocator.getLastKnownPosition();
      } catch (_) {/* none available */}
    }

    if (first == null) {
      // Couldn't place the driver anywhere → they can't be dispatched. Don't
      // pretend to be online; the caller surfaces this.
      return false;
    }
    try {
      await write(first);
      _lastPos = first;
    } catch (_) {
      // Write rejected (rules / network) → not actually online. Surface it
      // rather than leaving the toggle on with no location behind it.
      return false;
    }

    _sub = Geolocator.getPositionStream(
      locationSettings: driverLocationSettings(
        distanceFilter: 8,
        notificationText: 'Receiving ride requests',
      ),
    ).listen((p) {
      _lastPos = p;
      // The admin map doesn't need sub-second fidelity — cap writes to ~1/4s
      // so a moving car doesn't hammer Firestore.
      final now = DateTime.now();
      if (now.difference(_lastWriteAt).inSeconds < 4) return;
      _lastWriteAt = now;
      write(p);
    });

    // Heartbeat: the position stream only fires when the driver MOVES (8 m), so
    // a stationary driver would stop refreshing `updatedAt` and dispatch's
    // 2-minute ghost filter would drop them ("online but never gets requests").
    // Re-writing the last known position every 40 s keeps them dispatchable.
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 40), (_) {
      final p = _lastPos;
      if (p != null) {
        _lastWriteAt = DateTime.now();
        write(p);
      }
    });
    return true;
  }

  Future<void> goOffline(String uid) async {
    await _sub?.cancel();
    _sub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _lastPos = null;
    await _doc(uid).set({
      'online': false,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}

final driverLocationServiceProvider =
    Provider<DriverLocationService>((ref) => DriverLocationService());
