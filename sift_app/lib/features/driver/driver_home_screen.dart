import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/ride_repository.dart';
import '../../data/services/driver_location_service.dart';
import '../../data/services/notification_service.dart';
import '../auth/account_menu.dart';
import '../auth/session_controller.dart';

/// Driver home — map with an online/offline toggle. When online, a mock ride
/// request appears. UI-only.
class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  GoogleMapController? _controller;
  bool _online = false;
  bool _accepting = false;
  Ride? _offer;
  StreamSubscription<List<Ride>>? _offerSub;
  StreamSubscription<List<Ride>>? _activeSub;
  Timer? _tick; // 1s ticker to animate the offer countdown

  static const CameraPosition _fallback = CameraPosition(
    target: LatLng(-26.2041, 28.0473), // Johannesburg
    zoom: 15,
  );

  @override
  void initState() {
    super.initState();
    _centerOnCurrentPosition();
    // Idempotent: stores this device's FCM token so ride offers arrive even
    // when the app is backgrounded.
    final uid = ref.read(sessionProvider).uid;
    if (uid != null) {
      ref.read(notificationServiceProvider).register(uid);
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

  /// Toggle availability — streams GPS + listens for ride offers while online.
  Future<void> _setOnline(bool online) async {
    final session = ref.read(sessionProvider);
    final uid = session.uid;
    if (uid == null) return;

    if (online && !await _clearOfDebtCap(uid)) {
      if (mounted) setState(() => _online = false);
      return;
    }
    setState(() => _online = online);

    final service = ref.read(driverLocationServiceProvider);
    final repo = ref.read(rideRepositoryProvider);

    if (online) {
      await service.goOnline(uid: uid, name: session.name);
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_offer != null && mounted) setState(() {});
      });
      _offerSub = repo.watchOffersFor(uid).listen((offers) {
        setState(() => _offer = offers.isNotEmpty ? offers.first : null);
      });
      // Resume an already-accepted trip if one exists. This stream re-emits on
      // every ride-doc change (incl. the trip screen's own telemetry writes),
      // so navigation MUST be single-flight — see _goToTrip.
      _activeSub = repo.watchDriverActive(uid).listen((active) {
        if (active.isNotEmpty) _goToTrip(active.first.id);
      });
    } else {
      _offerSub?.cancel();
      _activeSub?.cancel();
      _tick?.cancel();
      _tick = null;
      setState(() => _offer = null);
      await service.goOffline(uid);
    }
  }

  /// Navigate to the trip screen, but never stack a second one: the active
  /// stream fires on every ride-doc write (telemetry every ~3s), and pushing
  /// per emission stacked maps until the app ran out of memory.
  bool _onTripScreen = false;

  void _goToTrip(String rideId) {
    if (_onTripScreen || !mounted) return;
    _onTripScreen = true;
    context.push(AppRouter.driverTrip, extra: rideId).whenComplete(() {
      _onTripScreen = false;
    });
  }

  Future<void> _accept(Ride offer) async {
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
    setState(() => _offer = null);
    try {
      await ref.read(rideRepositoryProvider).decline(offer.id);
    } catch (_) {}
  }

  @override
  void dispose() {
    _offerSub?.cancel();
    _activeSub?.cancel();
    _tick?.cancel();
    final uid = ref.read(sessionProvider).uid;
    if (uid != null && _online) {
      ref.read(driverLocationServiceProvider).goOffline(uid);
    }
    super.dispose();
  }

  Future<void> _centerOnCurrentPosition() async {
    try {
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
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _fallback,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
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

          // Bottom panel.
          Align(
            alignment: Alignment.bottomCenter,
            child: _bottomPanel(),
          ),
        ],
      ),
    );
  }

  Widget _statusPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _online ? AppColors.green : AppColors.muted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _online ? "You're online" : "You're offline",
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.dark),
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
              fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.dark),
        ),
        const SizedBox(height: 4),
        const Text('Go online to start receiving ride requests.',
            style: TextStyle(fontSize: 14, color: AppColors.muted)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: () => _setOnline(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            ),
            child: const Text('Go online',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
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
        if (offer == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: AppColors.green),
                ),
                SizedBox(width: 14),
                Text('Waiting for ride requests…',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
          )
        else
          _offerCard(offer),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => _setOnline(false),
            child: const Text('Go offline',
                style: TextStyle(
                    color: AppColors.muted, fontWeight: FontWeight.w600)),
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

  Widget _offerCard(Ride offer) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.selectedFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.selectedBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _countdown(offer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(offer.riderName,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.dark)),
                    Text(
                      offer.distanceKm > 0
                          ? '${offer.distanceKm.toStringAsFixed(1)} km trip'
                          : 'New ride request',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              Text('R${offer.fare.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.my_location, size: 16, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(offer.pickupAddress,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _accepting ? null : () => _decline(offer),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.dark,
                    side: const BorderSide(color: AppColors.line),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _accepting ? null : () => _accept(offer),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  child: _accepting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
