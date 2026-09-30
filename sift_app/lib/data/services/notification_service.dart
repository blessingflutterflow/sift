import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../features/auth/session_controller.dart';
import '../../features/chat/chat_screen.dart';
import '../repositories/parcel_repository.dart';
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
        // Payload is "type:id" so a tapped chat banner opens the chat, not the
        // trip screen. Older/simple payloads (just an id) fall back to 'ride'.
        final payload = resp.payload ?? '';
        if (payload.isEmpty) return;
        final i = payload.indexOf(':');
        final type = i > 0 ? payload.substring(0, i) : 'ride';
        final id = i > 0 ? payload.substring(i + 1) : payload;
        if (id.isEmpty && type != 'support') return;
        _routeTo({
          'type': type,
          'rideId': id,
          'parcelId': type == 'parcel' ? id : '',
        });
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
    // Admin broadcast: the full-screen takeover (AnnouncementGate) already shows
    // it live while the app is open, so don't also draw a tray banner.
    if (data['type'] == 'announcement') return;
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
      // Encode the type so the tap handler can open the right screen (chat vs
      // trip vs parcel).
      payload: '${data['type'] ?? 'ride'}:'
          '${(data['rideId'] ?? data['parcelId'] ?? '').toString()}',
    );
  }

  String _titleFor(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'chat':
        return 'New message';
      case 'parcel':
        return 'Parcel update';
      case 'support':
        return 'Sift Support';
      default:
        return 'Sift';
    }
  }

  /// Show the full-screen ringing incoming-call UI for a ride/parcel offer.
  Future<void> showOfferRing(Map<String, dynamic> data) =>
      showOfferCallkit(data);

  /// Stop the ringing offer UI (called when the offer is accepted/declined
  /// from inside the app, so the CallKit ring doesn't keep going).
  Future<void> endOfferRing() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }

  Future<void> _onCallEvent(CallEvent? event) async {
    if (event == null) return;
    final extra = Map<String, dynamic>.from(event.body['extra'] ?? {});
    // CRITICAL: zego_uikit_prebuilt_call uses flutter_callkit_incoming under the
    // hood, so ZEGO voice-call events arrive on this SAME stream. Only handle
    // our own ride/parcel offer rings (tagged 'siftOffer') and let ZEGO's call
    // events pass through untouched — otherwise we'd endAllCalls()/navigate and
    // kill an in-progress voice call.
    if (extra['siftOffer']?.toString() != '1') return;
    final rideId = (extra['rideId'] ?? '').toString();
    final parcelId = (extra['parcelId'] ?? '').toString();

    switch (event.event) {
      case Event.actionCallAccept:
        // Accepting the ring must actually accept the job, then open it. The
        // driver-home active-trip stream also resumes it, but we accept here so
        // it works even from a cold start / before the offer card mounts.
        await FlutterCallkitIncoming.endAllCalls();
        try {
          if (parcelId.isNotEmpty) {
            await _ref.read(parcelRepositoryProvider).accept(parcelId);
            AppRouter.router.go(AppRouter.driverHome);
            AppRouter.router.push(AppRouter.parcelDelivery, extra: parcelId);
          } else if (rideId.isNotEmpty) {
            await _ref.read(rideRepositoryProvider).accept(rideId);
            AppRouter.router.go(AppRouter.driverHome);
            AppRouter.router.push(AppRouter.driverTrip, extra: rideId);
          } else {
            AppRouter.router.go(AppRouter.driverHome);
          }
        } catch (_) {
          // Already taken / expired — just land on home, no dead-end.
          AppRouter.router.go(AppRouter.driverHome);
        }
        break;
      case Event.actionCallDecline:
      case Event.actionCallTimeout:
        try {
          if (parcelId.isNotEmpty) {
            await _ref.read(parcelRepositoryProvider).decline(parcelId);
          } else if (rideId.isNotEmpty) {
            await _ref.read(rideRepositoryProvider).decline(rideId);
          }
        } catch (_) {}
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
        if (rideId.isNotEmpty) unawaited(_openChat(rideId, isDriver));
        break;
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
      case 'support':
        AppRouter.router.push(AppRouter.support);
        break;
    }
  }

  /// Open the in-app chat for a ride straight from a message notification.
  /// Looks up the other party's name from the ride doc so the chat header is
  /// right; falls back to a generic label if the read fails.
  Future<void> _openChat(String rideId, bool isDriver) async {
    final session = _ref.read(sessionProvider);
    var otherName = isDriver ? 'Rider' : 'Driver';
    try {
      final r = (await _db.collection('rides').doc(rideId).get()).data();
      if (r != null) {
        otherName =
            (isDriver ? r['riderName'] : r['driverName'])?.toString() ??
                otherName;
      }
    } catch (_) {/* keep the fallback label */}
    AppRouter.router.push(
      AppRouter.chat,
      extra: ChatArgs(
        rideId: rideId,
        currentUserId: session.uid ?? '',
        currentUserRole: isDriver ? 'driver' : 'rider',
        currentUserName: session.name,
        otherUserName: otherName,
      ),
    );
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
      // Subscribe to the role broadcast topic so admin announcements reach the
      // user even when the app is closed (drivers → 'drivers', riders →
      // 'riders'). Individually-targeted announcements are pushed per-uid.
      try {
        final isDriver = _ref.read(sessionProvider).isDriver;
        await _messaging.subscribeToTopic(isDriver ? 'drivers' : 'riders');
        await _messaging.unsubscribeFromTopic(isDriver ? 'riders' : 'drivers');
      } catch (_) {}
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
    try {
      await _messaging.unsubscribeFromTopic('drivers');
      await _messaging.unsubscribeFromTopic('riders');
    } catch (_) {}
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
    // 'siftOffer' marks this as OUR ride/parcel offer ring so _onCallEvent can
    // distinguish it from ZEGO voice-call events on the shared CallKit stream.
    extra: <String, dynamic>{'siftOffer': '1', ...data},
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
  // Best-effort: on some OEM/Android builds starting the CallKit ring (a
  // phone-call foreground service) can throw — never let that take the app
  // down. If the ring fails, the in-app offer card + FCM still surface the job.
  try {
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  } catch (e, s) {
    FirebaseCrashlytics.instance
        .recordError(e, s, reason: 'showCallkitIncoming failed', fatal: false);
  }
}
