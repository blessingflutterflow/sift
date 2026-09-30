import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zego_uikit/zego_uikit.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/ride_repository.dart';
import '../../data/services/driver_location_service.dart';
import '../auth/session_controller.dart';
import '../chat/chat_screen.dart';
import '../ride_request/services/directions_service.dart';
import '../ride_request/widgets/star_rating.dart';
import '../trip/driver_nav_map.dart';
import '../trip/route_tracker.dart';
import '../trip/waiting_countdown.dart';

/// Driver's active-trip / navigation screen.
///
/// GPS streams into a RouteTracker (snapped position, live ETA, off-route
/// detection) and is mirrored — throttled — into the ride doc so the rider
/// tracks the car live. The map is a heading-up nav view; a Navigate button
/// hands off to Google Maps for turn-by-turn. Status controls run
/// arrived → start → complete, with a 5-minute waiting countdown at pickup.
class DriverTripScreen extends ConsumerStatefulWidget {
  const DriverTripScreen({super.key, required this.rideId});
  final String rideId;

  @override
  ConsumerState<DriverTripScreen> createState() => _DriverTripScreenState();
}

class _DriverTripScreenState extends ConsumerState<DriverTripScreen> {
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<Ride>? _rideSub;
  StreamSubscription<Position>? _posSub;
  final RouteTracker _tracker = RouteTracker();

  Ride? _ride;
  LatLng? _self;
  double? _speedKmh;
  RouteProgress? _progress;
  int _rating = 0;

  bool _fetchingRoute = false;
  DateTime _lastRouteAttempt = _epoch;
  bool _targetIsDestination = false;
  bool _sentArriving = false;

  // Telemetry throttle: at most one Firestore write per ~3s / 30m.
  DateTime _lastWriteAt = _epoch;
  LatLng? _lastWritePos;

  @override
  void initState() {
    super.initState();
    _rideSub =
        ref.read(rideRepositoryProvider).watch(widget.rideId).listen((r) {
      final isDest = r.status == RideStatus.inProgress;
      if (isDest != _targetIsDestination) {
        // Target flipped (pickup → destination): the old route is dead.
        _targetIsDestination = isDest;
        _tracker.clear();
        _progress = null;
      }
      setState(() => _ride = r);
      if (r.status == RideStatus.cancelled) {
        _posSub?.cancel();
        if (mounted) context.pop();
      } else if (r.status == RideStatus.completed) {
        _posSub?.cancel(); // stay to rate the rider
      } else {
        _ensureRoute();
      }
    });
    _streamLocation();
  }

  LatLng? _targetFor(Ride r) {
    if (r.status == RideStatus.inProgress) return r.destination;
    return r.pickup;
  }

  void _streamLocation() {
    _posSub = Geolocator.getPositionStream(
      locationSettings: driverLocationSettings(
        distanceFilter: 5,
        notificationText: 'Sharing your trip location with the rider',
      ),
    ).listen((p) {
      if (!mounted) return;
      final here = LatLng(p.latitude, p.longitude);
      final speed =
          (p.speed.isFinite && p.speed > 0) ? p.speed * 3.6 : null;
      setState(() {
        _self = here;
        _speedKmh = speed;
        _progress = _tracker.update(here, speedKmh: speed) ?? _progress;
      });
      _ensureRoute();
      _writeTelemetry(p, here);
      _maybeAutoArriving();
    });
  }

  /// Fetch Directions only when the tracker asks for it (no route, off-route,
  /// or stale) — not on a movement timer.
  Future<void> _ensureRoute() async {
    final r = _ride;
    final self = _self;
    if (r == null || self == null || _fetchingRoute) return;
    final target = _targetFor(r);
    if (target == null || !_tracker.needsRoute) return;
    final now = DateTime.now();
    if (now.difference(_lastRouteAttempt).inSeconds < 8) return;
    _lastRouteAttempt = now;
    _fetchingRoute = true;
    try {
      final res = await ref.read(directionsServiceProvider).route(self, target);
      if (!mounted) return;
      _tracker.setRoute(
        (res != null && res.points.length >= 2)
            ? res
            : RouteTracker.fallbackRoute(self, target),
      );
      setState(() {
        _progress = _tracker.update(self, speedKmh: _speedKmh) ?? _progress;
      });
    } finally {
      _fetchingRoute = false;
    }
  }

  void _writeTelemetry(Position p, LatLng here) {
    final r = _ride;
    if (r == null || r.status == RideStatus.completed) return;
    final now = DateTime.now();
    final moved = _lastWritePos == null
        ? double.infinity
        : RouteTracker.metersBetween(_lastWritePos!, here);
    if (now.difference(_lastWriteAt).inSeconds < 3 && moved < 30) return;
    _lastWriteAt = now;
    _lastWritePos = here;
    final gpsHeading =
        (p.heading.isFinite && p.heading >= 0) ? p.heading : null;
    ref
        .read(rideRepositoryProvider)
        .updateDriverTelemetry(
          widget.rideId,
          lat: here.latitude,
          lng: here.longitude,
          heading: _progress?.headingDeg ?? gpsHeading,
          speedKmh: _speedKmh,
        )
        .catchError((_) {});
  }

  /// Flip accepted → arriving once the driver closes within ~350m of pickup,
  /// so the rider's UI can say "your driver is nearby".
  void _maybeAutoArriving() {
    if (_sentArriving) return;
    final r = _ride;
    final prog = _progress;
    if (r == null || prog == null) return;
    if (r.status != RideStatus.accepted || prog.remainingKm > 0.35) return;
    _sentArriving = true;
    ref
        .read(rideRepositoryProvider)
        .setStatus(widget.rideId, RideStatus.arriving)
        .catchError((_) {});
  }

  bool _advancing = false;

  Future<void> _advance(RideStatus to) async {
    if (_advancing) return;
    setState(() => _advancing = true);
    final repo = ref.read(rideRepositoryProvider);
    try {
      // Completion is server-authoritative (fare + commission + ledger); every
      // other transition is a simple status write.
      if (to == RideStatus.completed) {
        await repo.complete(widget.rideId);
      } else {
        await repo.setStatus(widget.rideId, to);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update the trip. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _advancing = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await ref.read(rideRepositoryProvider).cancel(widget.rideId);
    } catch (_) {}
  }

  /// Hand off to Google Maps turn-by-turn for the current target. On a
  /// multi-stop trip to the destination, the intermediate stops are passed as
  /// ordered waypoints so Google Maps routes through them.
  Future<void> _openExternalNav() async {
    final r = _ride;
    if (r == null) return;
    final t = _targetFor(r);
    if (t == null) return;
    final viaStops = _targetIsDestination && r.stops.isNotEmpty;

    if (viaStops) {
      // dir URL is the only Google Maps deep link that supports waypoints.
      final wp = r.stops
          .map((s) => '${s.latLng.latitude},${s.latLng.longitude}')
          .join('|');
      final web = Uri.parse('https://www.google.com/maps/dir/?api=1'
          '&destination=${t.latitude},${t.longitude}'
          '&waypoints=${Uri.encodeComponent(wp)}'
          '&travelmode=driving');
      await launchUrl(web, mode: LaunchMode.externalApplication);
      return;
    }

    final native = Uri.parse(
        'google.navigation:q=${t.latitude},${t.longitude}&mode=d');
    if (await launchUrl(native, mode: LaunchMode.externalApplication)) return;
    final web = Uri.parse('https://www.google.com/maps/dir/?api=1'
        '&destination=${t.latitude},${t.longitude}&travelmode=driving');
    await launchUrl(web, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _rideSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _ride;
    final target = r == null ? null : _targetFor(r);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: target == null
                ? const ColoredBox(color: Color(0xFFE9ECF1))
                : DriverNavMap(
                    self: _self,
                    heading: _progress?.headingDeg,
                    target: target,
                    route: _progress?.remainingPath ?? const [],
                    targetIsDestination: _targetIsDestination,
                    // Show stop markers once the trip to the destination is on.
                    stops: _targetIsDestination
                        ? r!.stops.map((s) => s.latLng).toList()
                        : const [],
                    navigating: r!.status != RideStatus.arrived &&
                        r.status != RideStatus.completed,
                  ),
          ),
          Align(alignment: Alignment.bottomCenter, child: _panel(r)),
        ],
      ),
    );
  }

  Widget _panel(Ride? r) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Color(0x22000000), blurRadius: 25, offset: Offset(0, -5)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: r == null
              ? const SizedBox(
                  height: 80,
                  child: Center(child: CircularProgressIndicator()))
              : _content(r),
        ),
      ),
    );
  }

  Widget _content(Ride r) {
    if (r.status == RideStatus.completed) return _completedDriver(r);
    if (r.status == RideStatus.arrived) return _waitingAtPickup(r);

    final goingToPickup =
        r.status == RideStatus.accepted || r.status == RideStatus.arriving;
    final headline = goingToPickup
        ? 'Pick up ${r.riderName}'
        : 'Drop off at ${r.destinationLabel}';
    final sub = goingToPickup ? r.pickupAddress : r.destinationLabel;
    final prog = _progress;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(headline,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            if (prog != null) _etaChip(prog),
            const SizedBox(width: 8),
            _chatButton(r),
            const SizedBox(width: 8),
            _callButton(r),
          ],
        ),
        const SizedBox(height: 4),
        Text(sub,
            style: const TextStyle(color: AppColors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        if (!goingToPickup && r.stops.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.alt_route, size: 16, color: Color(0xFFFF6B2C)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Via ${r.stops.length} stop${r.stops.length == 1 ? '' : 's'}: '
                  '${r.stops.map((s) => s.label).join(' · ')}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.dark),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _actionFor(r.status)),
            const SizedBox(width: 12),
            _navigateButton(),
          ],
        ),
        if (goingToPickup)
          Center(
            child: TextButton(
              onPressed: _cancel,
              child: const Text('Cancel ride',
                  style: TextStyle(color: AppColors.muted)),
            ),
          ),
      ],
    );
  }

  Widget _etaChip(RouteProgress prog) {
    final label = prog.etaMin <= 0
        ? 'Arriving'
        : '${prog.etaMin} min · ${prog.remainingKm.toStringAsFixed(1)} km';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.selectedFill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: const TextStyle(
              color: AppColors.green, fontWeight: FontWeight.w800)),
    );
  }

  /// In-app voice call to the rider (ZEGOCLOUD VoIP — no phone number).
  Widget _callButton(Ride r) {
    return ZegoSendCallInvitationButton(
      isVideoCall: false,
      resourceID: 'zego_call',
      invitees: [ZegoUIKitUser(id: r.riderId, name: r.riderName)],
      buttonSize: const Size(40, 40),
      iconSize: const Size(40, 40),
      icon: ButtonIcon(
        icon: const Icon(Icons.call, color: AppColors.green),
        backgroundColor: AppColors.selectedFill,
      ),
    );
  }

  Widget _chatButton(Ride r) {
    return Material(
      color: AppColors.field,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          final session = ref.read(sessionProvider);
          context.push(
            AppRouter.chat,
            extra: ChatArgs(
              rideId: r.id,
              currentUserId: session.uid ?? '',
              currentUserRole: 'driver',
              currentUserName: session.name,
              otherUserName: r.riderName,
            ),
          );
        },
        child: const SizedBox(
          width: 40,
          height: 40,
          child:
              Icon(Icons.chat_bubble_outline, size: 18, color: AppColors.dark),
        ),
      ),
    );
  }

  Widget _navigateButton() {
    return SizedBox(
      width: 56,
      height: 54,
      child: OutlinedButton(
        onPressed: _openExternalNav,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.green,
          side: const BorderSide(color: AppColors.selectedBorder, width: 1.5),
          padding: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
        ),
        child: const Icon(Icons.navigation, size: 24),
      ),
    );
  }

  /// Arrived at pickup: 5-minute waiting countdown + start/cancel controls.
  Widget _waitingAtPickup(Ride r) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text("You've arrived",
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            _chatButton(r),
            const SizedBox(width: 8),
            _callButton(r),
          ],
        ),
        const SizedBox(height: 4),
        Text(r.pickupAddress,
            style: const TextStyle(color: AppColors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 14),
        WaitingCountdown(
          since: r.arrivedAt ?? DateTime.now(),
          title: 'Waiting for ${r.riderName}',
          subtitle: 'Free waiting time',
          expiredTitle: 'Waiting time is over',
          expiredSubtitle: 'You may cancel this trip without penalty',
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed:
                _advancing ? null : () => _advance(RideStatus.inProgress),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(27)),
            ),
            child: const Text('Start trip',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: _cancel,
            child: const Text('Cancel ride',
                style: TextStyle(color: AppColors.muted)),
          ),
        ),
      ],
    );
  }

  Future<void> _finishWithRating() async {
    if (_rating > 0) {
      try {
        await ref
            .read(rideRepositoryProvider)
            .rateAsDriver(widget.rideId, _rating);
      } catch (_) {}
    }
    if (mounted) context.pop();
  }

  Widget _completedDriver(Ride r) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: AppColors.green, size: 40),
        const SizedBox(height: 8),
        Text('Trip complete · R${r.displayFare.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        if (r.driverEarning != null) ...[
          const SizedBox(height: 4),
          Text(
            'You earn R${r.driverEarning!.toStringAsFixed(2)}'
            '${(r.waitFee ?? 0) > 0 ? '  ·  incl. R${r.waitFee!.toStringAsFixed(0)} waiting' : ''}',
            style: const TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ],
        const SizedBox(height: 8),
        Text('Rate ${r.riderName}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        StarRating(value: _rating, onChanged: (v) => setState(() => _rating = v)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _finishWithRating,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
            ),
            child: Text(_rating > 0 ? 'Submit' : 'Done',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _actionFor(RideStatus status) {
    final (label, RideStatus? next) = switch (status) {
      RideStatus.accepted ||
      RideStatus.arriving =>
        ("I've arrived", RideStatus.arrived),
      RideStatus.arrived => ('Start trip', RideStatus.inProgress),
      RideStatus.inProgress => ('Complete trip', RideStatus.completed),
      _ => ('Done', null),
    };
    return SizedBox(
      height: 54,
      child: ElevatedButton(
        onPressed: (next == null || _advancing) ? null : () => _advance(next),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
        ),
        child: _advancing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white))
            : Text(label,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
