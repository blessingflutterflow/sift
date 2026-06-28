import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zego_uikit/zego_uikit.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/map_style.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/payment_repository.dart';
import '../../data/repositories/ride_repository.dart';
import '../auth/session_controller.dart';
import '../chat/chat_screen.dart';
import '../payments/checkout_webview_screen.dart';
import '../trip/route_tracker.dart';
import '../trip/waiting_countdown.dart';
import 'ride_request_controller.dart';
import 'services/directions_service.dart';
import 'widgets/map_markers.dart';
import 'widgets/star_rating.dart';
import 'widgets/trip_map.dart';

/// Rider's matching screen — fully driven by the `rides/{id}` doc. While the
/// server is dispatching (`requested`) the rider sees the radar; once a driver
/// accepts, the real driver appears and their live position animates in.
class MatchingScreen extends ConsumerStatefulWidget {
  const MatchingScreen({super.key, required this.rideId});
  final String? rideId;

  @override
  ConsumerState<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends ConsumerState<MatchingScreen>
    with TickerProviderStateMixin {
  StreamSubscription<Ride>? _sub;
  Ride? _ride;

  // Live progress (snapped car, trimmed route, calibrated ETA) from the
  // driver's telemetry projected onto the fetched route.
  final RouteTracker _tracker = RouteTracker();
  RouteProgress? _progress;
  int _rating = 0;
  bool _fetchingRoute = false;
  DateTime _lastRouteAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasDest = false;

  late final AnimationController _radar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  LatLng get _pickup =>
      _ride?.pickup ??
      ref.read(rideRequestProvider).pickup ??
      const LatLng(-26.2041, 28.0473);

  /// Target the driver is heading to: pickup before boarding, destination after.
  LatLng? _targetFor(Ride r) {
    if (r.status == RideStatus.inProgress) return r.destination;
    if (r.status == RideStatus.accepted ||
        r.status == RideStatus.arriving ||
        r.status == RideStatus.arrived) {
      return r.pickup;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    MapMarkers.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    final id = widget.rideId;
    if (id != null) {
      _sub = ref.read(rideRepositoryProvider).watch(id).listen((r) {
        final isDest = r.status == RideStatus.inProgress;
        if (isDest != _wasDest) {
          // Target flipped (pickup → destination): the old route is dead.
          _wasDest = isDest;
          _tracker.clear();
          _progress = null;
        }
        setState(() => _ride = r);
        _track(r);
      });
    }
  }

  /// Project the driver's latest telemetry onto the route: snapped position,
  /// trimmed polyline and a recalibrated ETA on every update. Directions is
  /// only re-fetched when the tracker says so (no route / off-route / stale).
  Future<void> _track(Ride r) async {
    final driver = r.driverPos;
    final target = _targetFor(r);
    if (driver == null || target == null) return;

    if (_tracker.needsRoute && !_fetchingRoute) {
      final now = DateTime.now();
      if (now.difference(_lastRouteAttempt).inSeconds >= 8) {
        _lastRouteAttempt = now;
        _fetchingRoute = true;
        try {
          final res =
              await ref.read(directionsServiceProvider).route(driver, target);
          if (!mounted) return;
          _tracker.setRoute(
            (res != null && res.points.length >= 2)
                ? res
                : RouteTracker.fallbackRoute(driver, target),
          );
        } finally {
          _fetchingRoute = false;
        }
      }
    }

    final prog = _tracker.update(driver, speedKmh: r.driverSpeedKmh);
    if (prog != null && mounted) {
      setState(() => _progress = prog);
    }
  }

  Future<void> _cancel() async {
    final id = widget.rideId;
    if (id != null) {
      try {
        await ref.read(rideRepositoryProvider).cancel(id);
      } catch (_) {}
    }
    if (mounted) context.go(AppRouter.home);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _radar.dispose();
    super.dispose();
  }

  /// The red SOS pill shown during a live trip.
  Widget _sosButton(Ride r) {
    return Material(
      color: const Color(0xFFE0524D),
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _showSosSheet(r),
        child: const SizedBox(
          width: 46,
          height: 46,
          child: Center(
            child: Text('SOS',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5)),
          ),
        ),
      ),
    );
  }

  Future<void> _dial(String number) async {
    await launchUrl(Uri(scheme: 'tel', path: number));
  }

  /// Share live trip details (driver, vehicle, status + a live location link)
  /// with a trusted contact via the OS share sheet.
  void _openChat(Ride r) {
    final session = ref.read(sessionProvider);
    context.push(
      AppRouter.chat,
      extra: ChatArgs(
        rideId: r.id,
        currentUserId: session.uid ?? '',
        currentUserRole: 'rider',
        currentUserName: session.name,
        otherUserName: r.driverName ?? 'Driver',
      ),
    );
  }

  Future<void> _shareTrip(Ride r) async {
    final status = switch (r.status) {
      RideStatus.accepted => 'Driver is on the way to pick me up',
      RideStatus.arriving => 'Driver is arriving',
      RideStatus.arrived => 'Driver has arrived',
      RideStatus.inProgress => 'On the trip to ${r.destinationLabel}',
      _ => 'On a Sift trip',
    };
    final lines = <String>[
      "I'm on a Sift trip 🚗",
      'Driver: ${r.driverName ?? 'Assigned'}',
      'Vehicle: ${r.driverVehicle ?? 'N/A'}',
      if ((r.driverPhone ?? '').isNotEmpty) 'Driver phone: ${r.driverPhone}',
      'Status: $status',
      if (r.destinationLabel.isNotEmpty) 'Destination: ${r.destinationLabel}',
      '',
      'Follow my trip live in Sift:',
      'sift://trip/${r.id}',
    ];
    await SharePlus.instance
        .share(ShareParams(text: lines.join('\n'), subject: 'My Sift trip'));
  }

  /// Emergency action sheet — one tap to call emergency services. Shows the
  /// driver/vehicle so the rider can relay it to the operator.
  Future<void> _showSosSheet(Ride r) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.emergency_share,
                      color: Color(0xFFE0524D), size: 26),
                  const SizedBox(width: 10),
                  const Text('Emergency',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Call emergency services now. Stay on the line and share your '
                'live location.',
                style: TextStyle(color: AppColors.muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              // Trip details to read out to the operator.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.field,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Driver: ${r.driverName ?? 'Unknown'}',
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('Vehicle: ${r.driverVehicle ?? 'Unknown'}',
                        style:
                            const TextStyle(color: AppColors.muted)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _dial('112');
                  },
                  icon: const Icon(Icons.phone_in_talk),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE0524D),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27)),
                  ),
                  label: const Text('Call 112 (Emergency)',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _dial('10111');
                  },
                  icon: const Icon(Icons.local_police_outlined),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.dark,
                    side: const BorderSide(color: AppColors.line),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25)),
                  ),
                  label: const Text('Call Police (10111)',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// True while the rider is in a live trip (a driver is assigned and the trip
  /// hasn't ended) — when the SOS button is relevant.
  bool _isActiveTrip(Ride? r) =>
      r != null &&
      (r.status == RideStatus.accepted ||
          r.status == RideStatus.arriving ||
          r.status == RideStatus.arrived ||
          r.status == RideStatus.inProgress);

  @override
  Widget build(BuildContext context) {
    final ride = _ride;
    final searching = ride == null || ride.status == RideStatus.requested;

    return Scaffold(
      body: Stack(
        children: [
          // Searching → static map + radar; tracking → smooth live TripMap.
          if (searching)
            Positioned.fill(
              child: GoogleMap(
                initialCameraPosition:
                    CameraPosition(target: _pickup, zoom: 14.5),
                style: kDarkMapStyle,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                compassEnabled: false,
                markers: _searchMarkers(ride),
                onMapCreated: (_) {},
              ),
            )
          else
            Positioned.fill(
              child: TripMap(
                driver: _progress?.snapped ?? ride.driverPos,
                heading: _progress?.headingDeg ?? ride.driverHeading,
                target: _targetFor(ride) ?? ride.pickup,
                route: _progress?.remainingPath ?? const [],
                targetIsDestination: ride.status == RideStatus.inProgress,
                vehicleIsBike: ride.tierId == 'bike',
              ),
            ),

          if (searching)
            Center(
              child: AnimatedBuilder(
                animation: _radar,
                builder: (context, _) => CustomPaint(
                  size: const Size(300, 300),
                  painter: _RadarPainter(_radar.value),
                ),
              ),
            ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => context.go(AppRouter.home),
                      child: const SizedBox(
                          width: 46,
                          height: 46,
                          child: Icon(Icons.arrow_back, color: AppColors.dark)),
                    ),
                  ),
                  // SOS — emergency help, only during a live trip.
                  if (_isActiveTrip(ride)) _sosButton(ride!),
                ],
              ),
            ),
          ),

          Align(alignment: Alignment.bottomCenter, child: _sheet(ride)),
        ],
      ),
    );
  }

  Set<Marker> _searchMarkers(Ride? ride) {
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('pickup'),
        position: _pickup,
        icon: MapMarkers.person ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.9),
      ),
    };
    final cands = ride?.candidatePositions ?? const <LatLng>[];
    for (var i = 0; i < cands.length; i++) {
      markers.add(Marker(
        markerId: MarkerId('cand$i'),
        position: cands[i],
        icon: MapMarkers.car ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        flat: true,
      ));
    }
    // Typing bubble floating over the driver currently being asked.
    final idx = ride?.candidateIndex ?? -1;
    if (ride?.offeredTo != null && idx >= 0 && idx < cands.length) {
      markers.add(Marker(
        markerId: const MarkerId('typing'),
        position: cands[idx],
        icon: MapMarkers.bubble ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 1.7),
      ));
    }
    return markers;
  }

  Widget _sheet(Ride? ride) {
    final status = ride?.status ?? RideStatus.requested;
    return switch (status) {
      RideStatus.scheduled || RideStatus.requested => _shell(child: _finding()),
      RideStatus.accepted ||
      RideStatus.arriving ||
      RideStatus.arrived ||
      RideStatus.inProgress =>
        _shell(child: _driver(ride!)),
      RideStatus.completed => _shell(child: _completed(ride!)),
      RideStatus.cancelled => _shell(child: _ended('Ride cancelled')),
      RideStatus.expired =>
        _shell(child: _ended('No drivers available right now')),
    };
  }

  Widget _shell({required Widget child}) {
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
          child: child,
        ),
      ),
    );
  }

  Widget _finding() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Finding your driver…',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Offering your trip to nearby drivers.',
            style: TextStyle(fontSize: 14, color: AppColors.muted)),
        const SizedBox(height: 16),
        const LinearProgressIndicator(
            color: AppColors.green, backgroundColor: AppColors.line),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _cancel,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.muted,
            side: const BorderSide(color: AppColors.line),
            minimumSize: const Size(double.infinity, 48),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          ),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  /// A round icon action button (chat / share / call) on the driver card.
  Widget _circleAction({
    required Color bg,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
  }

  /// In-app voice call to the other party (ZEGOCLOUD VoIP — no phone number).
  Widget _voiceCallButton({
    required String calleeId,
    required String calleeName,
  }) {
    return ZegoSendCallInvitationButton(
      isVideoCall: false,
      resourceID: 'zego_call',
      invitees: [ZegoUIKitUser(id: calleeId, name: calleeName)],
      buttonSize: const Size(46, 46),
      iconSize: const Size(46, 46),
      icon: ButtonIcon(
        icon: const Icon(Icons.call, color: AppColors.green),
        backgroundColor: AppColors.selectedFill,
      ),
    );
  }

  /// Driver's KYC profile photo, falling back to a person icon.
  Widget _driverAvatar(String? url) {
    final hasPhoto = url != null && url.isNotEmpty;
    return CircleAvatar(
      radius: 26,
      backgroundColor: AppColors.field,
      backgroundImage: hasPhoto ? NetworkImage(url) : null,
      child: hasPhoto
          ? null
          : const Icon(Icons.person, color: AppColors.muted, size: 28),
    );
  }

  /// Driver's average rating, or "New driver" before they have any.
  Widget _driverRating(Ride r) {
    final rating = r.driverRating;
    final count = r.driverRatingCount ?? 0;
    if (rating == null || count == 0) {
      return const Padding(
        padding: EdgeInsets.only(top: 2),
        child: Text('New driver',
            style: TextStyle(fontSize: 13, color: AppColors.muted)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 15, color: AppColors.green),
          const SizedBox(width: 3),
          Text(rating.toStringAsFixed(1),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.dark)),
          const SizedBox(width: 4),
          Text('($count)',
              style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _driver(Ride r) {
    final eta = _progress?.etaMin;
    final label = switch (r.status) {
      RideStatus.arrived => 'Your driver has arrived',
      RideStatus.arriving => eta != null && eta > 0
          ? 'Driver is nearby · $eta min'
          : 'Driver is nearby',
      RideStatus.inProgress =>
        eta != null ? '$eta min to ${r.destinationLabel}' : 'On your trip',
      _ => eta != null ? 'Driver arriving · $eta min' : 'Driver on the way',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Text('R${r.fare.toStringAsFixed(0)}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ],
        ),
        if (r.status == RideStatus.arrived) ...[
          const SizedBox(height: 14),
          WaitingCountdown(
            since: r.arrivedAt ?? DateTime.now(),
            title: '${r.driverName ?? 'Your driver'} is waiting',
            subtitle: 'Please head to the pickup point',
            expiredTitle: 'Waiting time is over',
            expiredSubtitle: 'Your driver may cancel the trip',
          ),
        ],
        const SizedBox(height: 16),
        // Driver info on its own row so the name/vehicle never gets squeezed.
        Row(
          children: [
            _driverAvatar(r.driverPhoto),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.driverName ?? 'Driver',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  Text(r.driverVehicle ?? 'Vehicle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.muted)),
                  _driverRating(r),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Actions on their own row.
        Row(
          children: [
            _circleAction(
              bg: AppColors.selectedFill,
              icon: Icons.chat_bubble_outline,
              iconColor: AppColors.green,
              onTap: () => _openChat(r),
            ),
            const SizedBox(width: 10),
            _circleAction(
              bg: AppColors.field,
              icon: Icons.ios_share,
              iconColor: AppColors.dark,
              onTap: () => _shareTrip(r),
            ),
            if (r.driverId != null) ...[
              const SizedBox(width: 10),
              _voiceCallButton(
                calleeId: r.driverId!,
                calleeName: r.driverName ?? 'Driver',
              ),
            ],
          ],
        ),
        if (r.status == RideStatus.accepted ||
            r.status == RideStatus.arriving ||
            r.status == RideStatus.arrived) ...[
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: _cancel,
              child: const Text('Cancel ride',
                  style: TextStyle(color: AppColors.muted)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _finishWithRating() async {
    final id = widget.rideId;
    if (id != null && _rating > 0) {
      try {
        await ref.read(rideRepositoryProvider).rateAsRider(id, _rating);
      } catch (_) {}
    }
    if (mounted) context.go(AppRouter.home);
  }

  /// Payment state line on the completed sheet. Cash → tell the rider what to
  /// hand over; card → charging/paid/failed, with Pay now to recover failures.
  /// "Pay R… now" button — settles an unpaid trip via a fresh card checkout.
  Widget _payNowButton(Ride r) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: OutlinedButton(
        onPressed: _payingDebt ? null : () => _payOutstanding(r),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.green,
          side: const BorderSide(color: AppColors.selectedBorder, width: 1.5),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
        ),
        child: _payingDebt
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.green))
            : Text('Pay R${r.displayFare.toStringAsFixed(0)} now',
                style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _paymentLine(Ride r) {
    if (r.paymentMethod == 'cash') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.selectedFill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text('Pay R${r.displayFare.toStringAsFixed(0)} cash to your driver',
            style: const TextStyle(
                color: AppColors.green, fontWeight: FontWeight.w700)),
      );
    }
    if (r.paymentMethod == 'wallet') {
      if (r.paymentStatus == 'paid') {
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_balance_wallet,
                size: 18, color: AppColors.green),
            SizedBox(width: 6),
            Text('Paid from your Sift wallet',
                style: TextStyle(
                    color: AppColors.green, fontWeight: FontWeight.w700)),
          ],
        );
      }
      // Balance didn't cover it → settle the trip via card checkout.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Wallet balance didn't cover the trip",
              style: TextStyle(
                  color: Color(0xFFE0524D), fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _payNowButton(r),
        ],
      );
    }
    return switch (r.paymentStatus) {
      'paid' => const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.credit_score, size: 18, color: AppColors.green),
            SizedBox(width: 6),
            Text('Paid by card',
                style: TextStyle(
                    color: AppColors.green, fontWeight: FontWeight.w700)),
          ],
        ),
      'due' => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Card payment failed',
                style: TextStyle(
                    color: Color(0xFFE0524D), fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton(
                onPressed: _payingDebt ? null : () => _payOutstanding(r),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.green,
                  side: const BorderSide(
                      color: AppColors.selectedBorder, width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(23)),
                ),
                child: _payingDebt
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.green))
                    : Text('Pay R${r.displayFare.toStringAsFixed(0)} now',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      _ => const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.muted)),
            SizedBox(width: 8),
            Text('Charging your card…',
                style: TextStyle(color: AppColors.muted)),
          ],
        ),
    };
  }

  bool _payingDebt = false;

  Future<void> _payOutstanding(Ride r) async {
    setState(() => _payingDebt = true);
    try {
      final url =
          await ref.read(paymentRepositoryProvider).initDebtPayment(r.id);
      if (!mounted) return;
      // Pop the checkout as soon as the webhook flips the ride to paid.
      final doneSignal = ref
          .read(rideRepositoryProvider)
          .watch(r.id)
          .where((x) => x.paymentStatus == 'paid')
          .map((_) {});
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CheckoutWebViewScreen(
            url: url, title: 'Pay for your trip', doneSignal: doneSignal),
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not start the payment.')));
      }
    } finally {
      if (mounted) setState(() => _payingDebt = false);
    }
  }

  Widget _completed(Ride r) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: AppColors.green, size: 44),
        const SizedBox(height: 10),
        const Text('Trip complete',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
            'R${r.displayFare.toStringAsFixed(0)} · ${r.distanceKm.toStringAsFixed(1)} km'
            '${(r.waitFee ?? 0) > 0 ? ' · incl. R${r.waitFee!.toStringAsFixed(0)} waiting' : ''}',
            style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 10),
        _paymentLine(r),
        const SizedBox(height: 4),
        Text('Rate ${r.driverName ?? 'your driver'}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        StarRating(value: _rating, onChanged: (v) => setState(() => _rating = v)),
        const SizedBox(height: 12),
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
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _ended(String message) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: () => context.go(AppRouter.home),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
            ),
            child: const Text('Back home',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

/// Expanding radar rings + center dot, drawn while searching for a driver.
class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final radius = maxR * phase;
      final opacity = (1 - phase) * 0.45;
      canvas.drawCircle(center, radius,
          Paint()..color = AppColors.green.withValues(alpha: opacity * 0.4));
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = AppColors.green.withValues(alpha: opacity));
    }
    canvas.drawCircle(center, 9, Paint()..color = AppColors.green);
    canvas.drawCircle(
        center,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t;
}
