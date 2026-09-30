import 'dart:async';
import 'dart:io' show Platform;

import 'package:dash_bubble/dash_bubble.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The floating "you're online" bubble that hovers over other apps while the
/// driver is online (Bolt-style). Uses dash_bubble — a native Android floating
/// bubble (no second Flutter engine). Best-effort: a failure never blocks the
/// driver from going online.
class OverlayService {
  static const _appChannel = MethodChannel('sift/app');
  final bool _supported = !kIsWeb && Platform.isAndroid;

  /// Is "display over other apps" granted right now?
  Future<bool> isGranted() async {
    if (!_supported) return false;
    try {
      return await DashBubble.instance.hasOverlayPermission();
    } catch (_) {
      return false;
    }
  }

  /// Request the overlay + notification permissions (opens system settings).
  Future<void> requestPermission() async {
    if (!_supported) return;
    try {
      await DashBubble.instance.requestOverlayPermission();
      if (!await DashBubble.instance.hasPostNotificationsPermission()) {
        await DashBubble.instance.requestPostNotificationsPermission();
      }
    } catch (_) {}
  }

  /// Start the bubble. Returns a short status ('shown', 'no-permission',
  /// 'unsupported', 'start-failed', or 'error: …').
  Future<String> show({
    required bool online,
    required double earnings,
    bool hasOffer = false,
  }) async {
    if (!_supported) return 'unsupported';
    try {
      if (!await DashBubble.instance.hasOverlayPermission()) {
        return 'no-permission';
      }
      if (await DashBubble.instance.isRunning()) return 'shown';
      final ok = await DashBubble.instance.startBubble(
        bubbleOptions: BubbleOptions(
          bubbleIcon: 'sift_bubble',
          bubbleSize: 62,
          opacity: 1,
          startLocationX: 0,
          startLocationY: 200,
          enableClose: true,
          closeBehavior: CloseBehavior.following,
          distanceToClose: 100,
          enableAnimateToEdge: true,
          enableBottomShadow: true,
          keepAliveWhenAppExit: false,
        ),
        notificationOptions: NotificationOptions(
          id: 202,
          title: "Sift — you're online",
          body: 'Tap the bubble to open Sift.',
          channelId: 'sift_online_bubble',
          channelName: 'Online status',
        ),
        // Tapping the bubble brings the Sift app to the front.
        onTap: () {
          unawaited(
            _appChannel.invokeMethod('bringToFront').catchError((_) => null),
          );
        },
      );
      return ok ? 'shown' : 'start-failed';
    } catch (e) {
      return 'error: $e';
    }
  }

  /// dash_bubble shows a static icon, so there's no live data to push. Kept as a
  /// no-op so callers (driver home) don't need to change.
  Future<void> update({
    required bool online,
    required double earnings,
    bool hasOffer = false,
  }) async {}

  Future<void> hide() async {
    if (!_supported) return;
    try {
      if (await DashBubble.instance.isRunning()) {
        await DashBubble.instance.stopBubble();
      }
    } catch (_) {}
  }
}

final overlayServiceProvider = Provider<OverlayService>((ref) => OverlayService());
