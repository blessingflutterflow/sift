import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Share the app's root navigator with the ZEGOCLOUD call service so incoming
  // call UI can be shown over any screen. Must be set before runApp. (Native
  // calling isn't available on web — guarded in CallService.)
  if (!kIsWeb) {
    ZegoUIKitPrebuiltCallInvitationService()
        .setNavigatorKey(AppRouter.navigatorKey);
  }

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Crashlytics + Play-Integrity App Check are Android/iOS only — skip on web
  // (web has no Crashlytics; App Check would need a reCAPTCHA provider).
  if (!kIsWeb) {
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(!kDebugMode);
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };

    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? AndroidDebugProvider()
          : AndroidPlayIntegrityProvider(),
    );

    // In debug, force the App Check debug token to print at startup so it can
    // be registered once in the Firebase console.
    if (kDebugMode) {
      unawaited(
        FirebaseAppCheck.instance.getToken().then((_) {}, onError: (_) {}),
      );
    }
  }

  runApp(const ProviderScope(child: SiftApp()));
}

class SiftApp extends StatefulWidget {
  const SiftApp({super.key});

  @override
  State<SiftApp> createState() => _SiftAppState();
}

class _SiftAppState extends State<SiftApp> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  /// Route `sift://trip/<rideId>` links to the read-only live trip view, both
  /// for a cold start (initial link) and while the app is already running.
  Future<void> _initDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        // Let the splash settle its own navigation first, then overlay.
        Future.delayed(
            const Duration(milliseconds: 1200), () => _handleLink(initial));
      }
    } catch (_) {}
    _linkSub = _appLinks.uriLinkStream.listen(_handleLink, onError: (_) {});
  }

  void _handleLink(Uri uri) {
    if (uri.scheme == 'sift' &&
        uri.host == 'trip' &&
        uri.pathSegments.isNotEmpty) {
      AppRouter.router.push(AppRouter.follow, extra: uri.pathSegments.first);
    }
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Sift',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: AppRouter.router,
    );
  }
}
