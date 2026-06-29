import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../features/auth/session_controller.dart';
import '../repositories/ride_repository.dart';

/// FCM token lifecycle + notification UX:
///   • foreground chat / order-update notifications (heads-up banner),
///   • tap-to-open routing (chat / trip / parcel),
///   • incoming-call-style RING for driver ride/parcel offers (CallKit).
///
/// Background offer rings are shown by the top-level [fcmBackgroundHandler];
/// the accept/decline + routing happens here in the main isolate.
class NotificationService {
  NotificationService(this._ref);

  final Ref _ref;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  String? _token;
  String? _uid;
  bool _inited = false;
  StreamSubscription<String>? _refreshSub;

  static const _channel = AndroidNotificationChannel(
    'sift_messages',
    'Messages & updates',
    description: 'Chat messages and trip/parcel updates',
    importance: Importance.high,
  );

  /// One-time setup of local notifications + message/CallKit listeners.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (resp) {
        final rideId = resp.payload;
        if (rideId != null && rideId.isNotEmpty) {
          _routeTo({'type': 'ride', 'rideId': rideId});
        }
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // Foreground messages — Android suppresses FCM banners while the app is
    // open, so we draw them ourselves (or ring, for offers).
    FirebaseMessaging.onMessage.listen(_onForeground);
    // Tapped a notification that opened the app from background.
    FirebaseMessaging.onMessageOpenedApp.listen((m) => _routeTo(m.data));
    // Launched from a terminated state by tapping a notification.
    _messaging.getInitialMessage().then((m) {
      if (m != null) _routeTo(m.data);
    });

    // CallKit accept/decline for the ringing offer.
    FlutterCallkitIncoming.onEvent.listen(_onCallEvent);
  }

  Future<void> _onForeground(RemoteMessage m) async {
    final data = m.data;
    if (data['type'] == 'offer') {
      await showOfferRing(data);
      return;
    }
    final n = m.notification;
    final title = n?.title ?? _titleFor(data);
    final body = n?.body ?? '';
    await _local.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: (data['rideId'] ?? data['parcelId'] ?? '').toString(),
    );
  }

  String _titleFor(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'chat':
        return 'New message';
      case 'parcel':
        return 'Parcel update';
      default:
        return 'Sift';
    }
  }

  /// Show the full-screen ringing incoming-call UI for a ride/parcel offer.
  Future<void> showOfferRing(Map<String, dynamic> data) =>
      showOfferCallkit(data);

  Future<void> _onCallEvent(CallEvent? event) async {
    if (event == null) return;
    final extra = Map<String, dynamic>.from(event.body['extra'] ?? {});
    final rideId = (extra['rideId'] ?? '').toString();

    switch (event.event) {
      case Event.actionCallAccept:
        await FlutterCallkitIncoming.endAllCalls();
        // Open the driver to the offer; the live offer card handles acceptance.
        AppRouter.router.go(AppRouter.driverHome);
        break;
      case Event.actionCallDecline:
      case Event.actionCallTimeout:
        if (rideId.isNotEmpty) {
          try {
            await _ref.read(rideRepositoryProvider).decline(rideId);
          } catch (_) {}
        }
        await FlutterCallkitIncoming.endAllCalls();
        break;
      default:
        break;
    }
  }

  /// Route a notification tap to the right screen based on the user's role.
  void _routeTo(Map<String, dynamic> data) {
    final isDriver = _ref.read(sessionProvider).isDriver;
    final rideId = (data['rideId'] ?? '').toString();
    final parcelId = (data['parcelId'] ?? '').toString();
    switch (data['type']) {
      case 'offer':
        AppRouter.router.go(AppRouter.driverHome);
        break;
      case 'chat':
      case 'ride':
        if (rideId.isEmpty) break;
        if (isDriver) {
          AppRouter.router.push(AppRouter.driverTrip, extra: rideId);
        } else {
          AppRouter.router.push(AppRouter.matching, extra: rideId);
        }
        break;
      case 'parcel':
        if (parcelId.isEmpty) break;
        AppRouter.router.push(
          isDriver ? AppRouter.parcelDelivery : AppRouter.parcelTracking,
          extra: parcelId,
        );
        break;
    }
  }

  // --- token lifecycle ---
  Future<void> register(String uid) async {
    if (_uid == uid && _token != null) return;
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
      _uid = null;
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
    Provider<NotificationService>((ref) => NotificationService(ref));

/// Show the incoming-call-style ring for an offer. Top-level so the FCM
/// background isolate (which has no Riverpod) can call it too.
Future<void> showOfferCallkit(Map<String, dynamic> data) async {
  final id = (data['rideId'] ?? data['parcelId'] ?? 'offer').toString();
  final isParcel = data.containsKey('parcelId');
  final params = CallKitParams(
    id: id,
    nameCaller: isParcel ? 'Parcel delivery' : 'New ride request',
    appName: 'Sift',
    handle: (data['subtitle'] ?? 'Tap to view').toString(),
    type: 0, // audio
    duration: 20000,
    textAccept: 'Accept',
    textDecline: 'Decline',
    extra: <String, dynamic>{...data},
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      ringtonePath: 'system_ringtone_default',
      backgroundColor: '#FF6B2C',
      actionColor: '#4CAF50',
      isShowCallID: false,
    ),
    ios: const IOSParams(handleType: 'generic'),
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
}
