import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// FCM token lifecycle: ask permission (Android 13+), store this device's
/// token on `users/{uid}.fcmTokens`, follow token rotations, and remove the
/// token on sign-out so a sold/shared phone stops getting pushes.
///
/// Display needs no client code: the senders use notification-type messages,
/// which Android shows natively while the app is backgrounded — and when the
/// app is open, the live Firestore streams already drive the UI.
class NotificationService {
  NotificationService({FirebaseFirestore? db, FirebaseMessaging? messaging})
      : _db = db ?? FirebaseFirestore.instance,
        _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseFirestore _db;
  final FirebaseMessaging _messaging;

  String? _token;
  String? _uid;
  StreamSubscription<String>? _refreshSub;

  Future<void> register(String uid) async {
    if (_uid == uid && _token != null) return; // already registered
    _uid = uid;
    try {
      await _messaging.requestPermission();
      final token = await _messaging.getToken();
      if (token != null) {
        _token = token;
        await _save(uid, token);
      }
      _refreshSub ??= _messaging.onTokenRefresh.listen((t) {
        _token = t;
        final u = _uid;
        if (u != null) _save(u, t);
      });
    } catch (_) {
      _uid = null; // retry on next register() call
    }
  }

  Future<void> _save(String uid, String token) {
    return _db.collection('users').doc(uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));
  }

  Future<void> unregister() async {
    final uid = _uid;
    final token = _token;
    _uid = null;
    if (uid == null || token == null) return;
    await _db.collection('users').doc(uid).update({
      'fcmTokens': FieldValue.arrayRemove([token]),
    }).catchError((_) {});
  }
}

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService());
