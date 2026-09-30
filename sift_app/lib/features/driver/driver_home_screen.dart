import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/parcel.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../data/repositories/parcel_repository.dart';
import '../../data/repositories/ride_repository.dart';
import '../../data/services/driver_location_service.dart';
import '../../data/services/notification_service.dart';
import '../../data/services/overlay_service.dart';
import '../auth/account_menu.dart';
import '../auth/session_controller.dart';
import '../ride_request/widgets/map_markers.dart';
import '../trip/route_tracker.dart';

/// Driver home — map with an online/offline toggle. When online, a mock ride
/// request appears. UI-only.
class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen>
    with WidgetsBindingObserver {
  GoogleMapController? _controller;
  bool _online = false;
  // True from launch until we've decided whether to resume an active trip —
  // shows a loader instead of flashing the "go online" home, and keeps the
  // home map unbuilt so it never co-exists with the trip map (OOM guard).
  bool _resuming = true;
  bool _accepting = false;
  Ride? _offer;
  Parcel? _parcelOffer;
  StreamSubscription<List<Ride>>? _offerSub;
  StreamSubscription<List<Ride>>? _activeSub;
  StreamSubscription<List<Parcel>>? _parcelOfferSub;
  StreamSubscription<List<Parcel>>? _parcelActiveSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _blockedSub;
  Timer? _tick; // 1s ticker to animate the offer countdown

  static const CameraPosition _fallback = CameraPosition(
    target: LatLng(-26.2041, 28.0473), // Johannesburg
    zoom: 15,
  );

  // The driver's own live position, shown as a car on the map.
  LatLng? _myPos;
  double _myHeading = 0;
  StreamSubscription<Position>? _posSub;

  // Today's earnings, shown in the top pill.
  double _todayEarnings = 0;
  StreamSubscription<List<LedgerEntry>>? _ledgerSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _centerOnCurrentPosition();
    MapMarkers.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    // Follow the driver's position so their car marker tracks them.
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 8),
    ).listen((pos) {
      if (!mounted) return;
      setState(() {
        _myPos = LatLng(pos.latitude, pos.longitude);
        if (pos.heading >= 0) _myHeading = pos.heading;
      });
    });
    // Idempotent: stores this device's FCM token so ride offers arrive even
    // when the app is backgrounded.
    final uid = ref.read(sessionProvider).uid;
    if (uid != null) {
      ref.read(notificationServiceProvider).register(uid);
      // Re-attach to server state every time the app opens: resume an in-flight
      // trip and restore the online state — survives a crash / cold start.
      _recoverSession(uid);
      // Today's earnings for the top pill — sum of trip/parcel earnings dated
      // today across the driver's ledger.
      _ledgerSub =
          ref.read(ledgerRepositoryProvider).watchEntries(uid).listen((entries) {
        final now = DateTime.now();
        double total = 0;
        for (final e in entries) {
          final t = e.createdAt;
          if (t != null &&
              t.year == now.year &&
              t.month == now.month &&
              t.day == now.day) {
            total += e.driverEarning ?? 0;
          }
        }
        if (mounted) setState(() => _todayEarnings = total);
        _syncOverlay();
      });
    }
  }

  /// Over-cap cash-commission debt blocks going online (D7). Returns true
  /// when the driver is clear to work; fails open on read errors.
  Future<bool> _clearOfDebtCap(String uid) async {
    try {
      final db = FirebaseFirestore.instance;
      final results = await Future.wait([
        db.collection('ledgers').doc(uid).get(),
        db.collection('config').doc('pricing').get(),
      ]);
      final balance =
          (results[0].data()?['balance'] as num?)?.toDouble() ?? 0;
      final cap =
          (results[1].data()?['cashDebtCapZar'] as num?)?.toDouble() ?? 300;
      if (balance < cap) return true;
      if (!mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Commission payment needed',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          content: Text(
              'You owe Sift R${balance.toStringAsFixed(0)} in commission from '
              'cash trips. Settle it to keep accepting rides.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later',
                  style: TextStyle(color: AppColors.muted)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                context.push(AppRouter.driverEarnings);
              },
              child: const Text('Pay now',
                  style: TextStyle(
                      color: AppColors.green, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );
      return false;
    } catch (_) {
      return true; // never strand a driver on a read hiccup
    }
  }

  /// Establishes location readiness BEFORE the driver goes online — Sift can't
  /// dispatch a driver it can't place on the map, so we never flip "online"
  /// until GPS is on AND location permission is granted. Returns true only when
  /// both hold; otherwise it tells the driver exactly what to fix (rather than
  /// silently going online but never receiving requests).
  Future<bool> _ensureLocationReady() async {
    // 1) Device GPS / location services must be on.
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!mounted) return false;
      final open = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Turn on location'),
          content: const Text(
              'Sift needs your device location (GPS) switched on to match you '
              'with nearby riders. Turn it on to go online.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Not now')),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Open settings')),
          ],
        ),
      );
      if (open == true) await Geolocator.openLocationSettings();
      return false;
    }

    // 2) App-level location permission — request it if we haven't asked yet.
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    // Permanently denied → the OS won't prompt again; send them to Settings.
    if (perm == LocationPermission.deniedForever) {
      if (!mounted) return false;
      final open = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Allow location access'),
          content: const Text(
              'Location permission is turned off for Sift. Enable it in '
              'Settings so we can send you nearby ride requests.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Not now')),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Open settings')),
          ],
        ),
      );
      if (open == true) await Geolocator.openAppSettings();
      return false;
    }

    // Still denied (driver dismissed the prompt) → can't go online.
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.unableToDetermine) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Sift needs location access to match you with nearby riders.'),
          backgroundColor: Color(0xFFE0524D),
        ));
      }
      return false;
    }

    // whileInUse / always → good to go.
    return true;
  }

  /// Make sure a ride offer can actually RING this phone before the driver goes
  /// online. Two things silently kill the ring on modern Android:
  ///   • notifications not allowed (Android 13+) — nothing shows at all;
  ///   • the full-screen-intent permission being off (Android 14+) — the
  ///     incoming-call screen never appears, so the phone "doesn't ring".
  /// Both are blocking: a driver who can't be alerted shouldn't be online.
  Future<bool> _ensureRingReady() async {
    // 1) Notification permission.
    try {
      final messaging = FirebaseMessaging.instance;
      var settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
        settings = await messaging.requestPermission();
      }
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        if (!mounted) return false;
        final open = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Allow notifications'),
            content: const Text(
                'Sift needs notifications switched on to ring you when a ride '
                'request comes in. Turn them on to go online.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Not now')),
              TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Open settings')),
            ],
          ),
        );
        if (open == true) await Geolocator.openAppSettings();
        return false;
      }
    } catch (_) {/* if the check itself fails, don't hard-block */}

    // 2) Full-screen intent (Android 14+) — required for the ringing screen.
    try {
      final can = await FlutterCallkitIncoming.canUseFullScreenIntent();
      if (can == false) {
        if (!mounted) return false;
        final open = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Allow full-screen alerts'),
            content: const Text(
                'To ring you like a phone call when a request arrives, Android '
                'needs "full-screen notifications" allowed for Sift. Without '
                'it your phone stays silent on new requests.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Not now')),
              TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Allow')),
            ],
          ),
        );
        if (open == true) {
          await FlutterCallkitIncoming.requestFullIntentPermission();
        }
        return false;
      }
    } catch (_) {
      // Older Android (or the API is unavailable) — full-screen intent isn't
      // gated there, so this is not a blocker.
    }
    return true;
  }

  /// Toggle availability — streams GPS + listens for ride offers while online.
  Future<void> _setOnline(bool online) async {
    final session = ref.read(sessionProvider);
    final uid = session.uid;
    if (uid == null) return;

    // Blocked drivers can't go online at all (admin can suspend an account).
    if (online && await _isBlocked(uid)) {
      if (mounted) {
        setState(() => _online = false);
        _showBlockedMessage();
      }
      return;
    }

    if (online && !await _clearOfDebtCap(uid)) {
      if (mounted) setState(() => _online = false);
      return;
    }

    // Establish GPS + location permission BEFORE flipping online. The driver
    // never appears online (and never gets a foreground-service notification)
    // until we can actually place them for dispatch.
    if (online && !await _ensureLocationReady()) {
      if (mounted) setState(() => _online = false);
      return;
    }

    // ...and make sure offers can actually ring this phone. A driver who can't
    // be alerted would just sit "online" missing every request.
    if (online && !await _ensureRingReady()) {
      if (mounted) setState(() => _online = false);
      return;
    }

    setState(() => _online = online);

    final service = ref.read(driverLocationServiceProvider);
    final repo = ref.read(rideRepositoryProvider);

    if (online) {
      final category = await _driverCategory(uid);
      final located = await service.goOnline(
          uid: uid, name: session.name, category: category);
      // No location → the driver isn't actually dispatchable. Don't leave them
      // falsely "online"; tell them why no requests are coming.
      if (!located) {
        if (mounted) {
          setState(() => _online = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Couldn\'t get your location. Turn on GPS / allow location to '
                'receive ride requests.'),
            backgroundColor: Color(0xFFE0524D),
          ));
        }
        return;
      }
      // If the admin blocks this driver mid-shift, kick them offline at once.
      _blockedSub = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots()
          .listen((d) {
        if (d.data()?['blocked'] == true && _online) {
          _setOnline(false);
          _showBlockedMessage();
        }
      });
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_offer != null && mounted) setState(() {});
      });
      _offerSub = repo.watchOffersFor(uid).listen((offers) {
        setState(() => _offer = offers.isNotEmpty ? offers.first : null);
        _syncOverlay();
      });
      // Parcel jobs are offered the same way as rides.
      final parcelRepo = ref.read(parcelRepositoryProvider);
      _parcelOfferSub = parcelRepo.watchOffersFor(uid).listen((offers) {
        setState(() => _parcelOffer = offers.isNotEmpty ? offers.first : null);
        _syncOverlay();
      });
      // Floating "you're online" bubble over other apps (Bolt-style,
      // dash_bubble). Ask for the overlay permission now; the bubble itself
      // appears when the driver LEAVES the app (didChangeAppLifecycleState) and
      // hides when they return — no point floating it over Sift itself.
      final overlay = ref.read(overlayServiceProvider);
      if (!await overlay.isGranted()) {
        await overlay.requestPermission();
      }
      // NOTE: active-trip resume (_activeSub / _parcelActiveSub) is NOT started
      // here — it runs always via _recoverSession so an accepted job is picked
      // up even after a crash, before the driver toggles online again.
    } else {
      _offerSub?.cancel();
      _parcelOfferSub?.cancel();
      _blockedSub?.cancel();
      _blockedSub = null;
      _tick?.cancel();
      _tick = null;
      setState(() {
        _offer = null;
        _parcelOffer = null;
      });
      ref.read(overlayServiceProvider).hide();
      await service.goOffline(uid);
    }
  }

  /// Push the current online/earnings/offer state into the floating bubble.
  void _syncOverlay() {
    if (!_online) return;
    ref.read(overlayServiceProvider).update(
          online: _online,
          earnings: _todayEarnings,
          hasOffer: _offer != null || _parcelOffer != null,
        );
  }

  /// Chat-head behaviour: the bubble appears only while online AND the driver
  /// has left the Sift app; it hides the moment Sift is back on screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final overlay = ref.read(overlayServiceProvider);
    if (state == AppLifecycleState.resumed) {
      overlay.hide();
    } else if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _online &&
        !_onTripScreen) {
      overlay.show(
        online: true,
        earnings: _todayEarnings,
        hasOffer: _offer != null || _parcelOffer != null,
      );
    }
  }

  /// Re-attach to server state on every app open — independent of the online
  /// toggle and resilient to crashes. An accepted trip/parcel lives on the
  /// server; the app's only job is to resume the right screen and restore the
  /// online state the driver had when the app last closed (or crashed).
  Future<void> _recoverSession(String uid) async {
    final repo = ref.read(rideRepositoryProvider);
    final parcelRepo = ref.read(parcelRepositoryProvider);

    // Always-on: an in-flight trip/parcel re-opens its screen the moment the
    // app launches, even before (or without) the driver going online again.
    // These streams re-emit on every doc write, so navigation is single-flight
    // (see _goToTrip / _goToParcel).
    _activeSub = repo.watchDriverActive(uid).listen((active) {
      if (active.isNotEmpty) _goToTrip(active.first.id);
    });
    _parcelActiveSub = parcelRepo.watchDriverActive(uid).listen((active) {
      if (active.isNotEmpty) _goToParcel(active.first.id);
    });

    // Decide the first screen: if a trip/parcel is already active the streams
    // above jump straight to it; otherwise reveal the home UI. Until then the
    // build shows a loader (no "go online" flash, no second map).
    try {
      final ride = await repo
          .watchDriverActive(uid)
          .first
          .timeout(const Duration(seconds: 5), onTimeout: () => const <Ride>[]);
      final parcels = ride.isEmpty
          ? await parcelRepo.watchDriverActive(uid).first.timeout(
              const Duration(seconds: 5),
              onTimeout: () => const <Parcel>[])
          : const <Parcel>[];
      if (ride.isEmpty && parcels.isEmpty && mounted && _resuming) {
        setState(() => _resuming = false);
      }
    } catch (_) {
      if (mounted && _resuming) setState(() => _resuming = false);
    }

    // Restore "online" if that's how the driver left the app. After a crash,
    // goOffline never ran, so driver_locations still reads online:true — which
    // is exactly the signal that they should resume working. Blocked → stay off.
    try {
      final loc = await FirebaseFirestore.instance
          .collection('driver_locations')
          .doc(uid)
          .get();
      final wasOnline = loc.data()?['online'] == true;
      if (wasOnline && mounted && !_online && !await _isBlocked(uid)) {
        await _setOnline(true);
      }
    } catch (_) {/* offline read failure — driver can toggle manually */}
  }

  /// Admin-assigned service category (bike/go/xl/max/parcel), stamped onto
  /// driver_locations so dispatch only offers matching requests. Null = the
  /// driver is eligible for everything (not yet categorised).
  Future<String?> _driverCategory(String uid) async {
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final c = doc.data()?['category'];
      return (c is String && c.isNotEmpty) ? c : null;
    } catch (_) {
      return null;
    }
  }

  /// Has the admin blocked this account? Read fresh before going online.
  Future<bool> _isBlocked(String uid) async {
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      return doc.data()?['blocked'] == true;
    } catch (_) {
      return false; // never trap a driver offline on a transient read error
    }
  }

  void _showBlockedMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
          'Your account has been blocked. Please contact Sift support.'),
      backgroundColor: Color(0xFFE0524D),
    ));
  }

  /// Navigate to the trip screen, but never stack a second one: the active
  /// stream fires on every ride-doc write (telemetry every ~3s), and pushing
  /// per emission stacked maps until the app ran out of memory.
  bool _onTripScreen = false;

  void _goToTrip(String rideId) {
    if (_onTripScreen || !mounted || rideId.isEmpty) return;
    // setState so build() swaps the home map for a loader before we push (so
    // the two maps never co-exist), and clears the resuming flag.
    setState(() {
      _onTripScreen = true;
      _resuming = false;
    });
    // Navigate after the current frame: the active stream can emit mid-build,
    // and pushing a route during build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _onTripScreen = false;
        return;
      }
      context.push(AppRouter.driverTrip, extra: rideId).whenComplete(() {
        if (mounted) {
          setState(() => _onTripScreen = false); // rebuild the home map
        } else {
          _onTripScreen = false;
        }
      });
    });
  }

  bool _onParcelScreen = false;

  void _goToParcel(String parcelId) {
    if (_onParcelScreen || !mounted || parcelId.isEmpty) return;
    setState(() {
      _onParcelScreen = true;
      _resuming = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _onParcelScreen = false;
        return;
      }
      context.push(AppRouter.parcelDelivery, extra: parcelId).whenComplete(() {
        if (mounted) {
          setState(() => _onParcelScreen = false);
        } else {
          _onParcelScreen = false;
        }
      });
    });
  }

  Future<void> _acceptParcel(Parcel offer) async {
    ref.read(notificationServiceProvider).endOfferRing();
    setState(() => _accepting = true);
    try {
      await ref.read(parcelRepositoryProvider).accept(offer.id);
      if (mounted) {
        setState(() => _parcelOffer = null);
        _goToParcel(offer.id);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That parcel was already taken.')),
        );
        setState(() => _parcelOffer = null);
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _declineParcel(Parcel offer) async {
    ref.read(notificationServiceProvider).endOfferRing();
    setState(() => _parcelOffer = null);
    try {
      await ref.read(parcelRepositoryProvider).decline(offer.id);
    } catch (_) {}
  }

  Future<void> _accept(Ride offer) async {
    ref.read(notificationServiceProvider).endOfferRing();
    setState(() => _accepting = true);
    try {
      await ref.read(rideRepositoryProvider).accept(offer.id);
      if (mounted) {
        setState(() => _offer = null);
        _goToTrip(offer.id);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That ride was already taken.')),
        );
        setState(() => _offer = null);
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _decline(Ride offer) async {
    ref.read(notificationServiceProvider).endOfferRing();
    setState(() => _offer = null);
    try {
      await ref.read(rideRepositoryProvider).decline(offer.id);
    } catch (_) {}
  }

  /// The driver's own vehicle as a car marker at their live position.
  Set<Marker> _myCarMarker() {
    final pos = _myPos;
    if (pos == null || MapMarkers.car == null) return const {};
    return {
      Marker(
        markerId: const MarkerId('me'),
        position: pos,
        icon: MapMarkers.car!,
        rotation: _myHeading,
        anchor: const Offset(0.5, 0.5),
        flat: true,
      ),
    };
  }

  @override
  void dispose() {
    _offerSub?.cancel();
    _activeSub?.cancel();
    _parcelOfferSub?.cancel();
    _parcelActiveSub?.cancel();
    _blockedSub?.cancel();
    _posSub?.cancel();
    _ledgerSub?.cancel();
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ref.read(overlayServiceProvider).hide();
    final uid = ref.read(sessionProvider).uid;
    if (uid != null && _online) {
      ref.read(driverLocationServiceProvider).goOffline(uid);
    }
    super.dispose();
  }

  Future<void> _centerOnCurrentPosition() async {
    try {
      // If we already have a live fix from the position stream, snap there
      // instantly — no waiting on a fresh GPS read.
      final cached = _myPos;
      if (cached != null) {
        await _controller?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: cached, zoom: 16),
          ),
        );
      }
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      await _controller?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: LatLng(pos.latitude, pos.longitude), zoom: 16),
        ),
      );
    } catch (_) {/* keep fallback */}
  }

  @override
  Widget build(BuildContext context) {
    // While resuming, or while the trip/parcel screen is on top, don't build
    // the home map. This (a) avoids the "go online" flash on relaunch and
    // (b) guarantees only one Google Map is ever mounted — two at once is the
    // memory spike that was crashing the app at "Complete trip".
    if (_resuming || _onTripScreen || _onParcelScreen) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.green),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _fallback,
              // Show the driver's own car marker instead of the blue dot.
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              markers: _myCarMarker(),
              onMapCreated: (c) {
                _controller = c;
                _centerOnCurrentPosition();
              },
            ),
          ),

          // Status pill + account menu at the top.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _statusPill(),
                  const Spacer(),
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 3,
                    shadowColor: Colors.black26,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => showAccountMenu(context, ref),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(Icons.person_outline,
                            size: 22, color: AppColors.dark),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Recenter button (sits just above the bottom panel) + the panel.
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _recenterButton(),
                  ),
                ),
                _bottomPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tap to recenter the map on the driver's own car ("where am I?").
  Widget _recenterButton() {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _centerOnCurrentPosition,
        child: const SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.my_location, size: 24, color: AppColors.green),
        ),
      ),
    );
  }

  /// Top pill — today's earnings (with a small online/offline status dot).
  Widget _statusPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'R ${_todayEarnings.toStringAsFixed(2)}',
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.dark),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _online ? AppColors.green : AppColors.muted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text('Today',
                  style: TextStyle(fontSize: 14, color: AppColors.muted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bottomPanel() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(color: Color(0x22000000), blurRadius: 25, offset: Offset(0, -5)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: _online ? _onlineContent() : _offlineContent(),
        ),
      ),
    );
  }

  Widget _offlineContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          "You're offline",
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.dark),
        ),
        const SizedBox(height: 6),
        const Text('Go online to start receiving ride requests.',
            style: TextStyle(fontSize: 16, color: AppColors.muted)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 62,
          child: ElevatedButton(
            onPressed: () => _setOnline(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(31)),
            ),
            child: const Text('Go online',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _onlineContent() {
    final offer = _offer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (offer != null)
          _offerCard(offer)
        else if (_parcelOffer != null)
          _parcelOfferCard(_parcelOffer!)
        else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 3, color: AppColors.green),
                ),
                SizedBox(width: 16),
                Text('Waiting for requests…',
                    style: TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () => _setOnline(false),
            child: const Text('Go offline',
                style: TextStyle(
                    fontSize: 16,
                    color: AppColors.muted,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _countdown(Ride offer) {
    final exp = offer.offerExpiresAt;
    final remaining = exp == null
        ? 15
        : exp.difference(DateTime.now()).inSeconds.clamp(0, 15);
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: remaining / 15,
            strokeWidth: 3,
            backgroundColor: Colors.white,
            color: AppColors.green,
          ),
          Text('$remaining',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _parcelOfferCard(Parcel offer) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.local_shipping_outlined,
                color: AppColors.green, size: 22),
            const SizedBox(width: 8),
            const Text('Parcel delivery',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('R${offer.fare.toStringAsFixed(0)}',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
            '${offer.stops.length} drop-off${offer.stops.length == 1 ? '' : 's'} · ${offer.distanceKm.toStringAsFixed(1)} km',
            style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 4),
        Text('Pickup: ${offer.pickupAddress}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: AppColors.muted)),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _accepting ? null : () => _declineParcel(offer),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  side: const BorderSide(color: AppColors.line),
                  minimumSize: const Size(0, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                ),
                child: const Text('Decline'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: _accepting ? null : () => _acceptParcel(offer),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(0, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                ),
                child: _accepting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : const Text('Accept delivery',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// How far the driver currently is from the pickup, e.g. "2.4 km away".
  String? _pickupAway(Ride offer) {
    final me = _myPos;
    if (me == null) return null;
    final km = RouteTracker.metersBetween(me, offer.pickup) / 1000;
    return km < 1
        ? '${(km * 1000).round()} m away'
        : '${km.toStringAsFixed(1)} km away';
  }

  /// One labelled address line on the offer card (pickup / stop / drop-off).
  Widget _addrRow(IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color)),
                Text(value,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _offerCard(Ride offer) {
    final away = _pickupAway(offer);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.selectedFill,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.selectedBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _countdown(offer),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(offer.riderName,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: AppColors.dark)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (offer.distanceKm > 0)
                          '${offer.distanceKm.toStringAsFixed(1)} km trip'
                        else
                          'New ride request',
                        if (offer.stops.isNotEmpty)
                          '${offer.stops.length} stop${offer.stops.length == 1 ? '' : 's'}',
                      ].join(' · '),
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              Text('R${offer.fare.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 14),
          // Distance from the driver to the pickup — the first thing a driver
          // wants to know before accepting.
          if (away != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Icon(Icons.directions_car,
                      size: 20, color: AppColors.green),
                  const SizedBox(width: 10),
                  Text('$away from you',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.green)),
                ],
              ),
            ),
          // Pickup → drop-off, so the driver sees the whole job before accepting.
          _addrRow(Icons.my_location, 'Pickup', offer.pickupAddress,
              AppColors.muted),
          if (offer.stops.isNotEmpty)
            for (int i = 0; i < offer.stops.length; i++)
              _addrRow(Icons.alt_route, 'Stop ${i + 1}', offer.stops[i].label,
                  const Color(0xFFFF6B2C)),
          _addrRow(Icons.location_on, 'Drop-off',
              offer.destinationLabel.isEmpty ? '—' : offer.destinationLabel,
              AppColors.green),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _accepting ? null : () => _decline(offer),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.dark,
                    side: const BorderSide(color: AppColors.line),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  child: const Text('Decline',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ElevatedButton(
                  onPressed: _accepting ? null : () => _accept(offer),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  child: _accepting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white))
                      : const Text('Accept',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
