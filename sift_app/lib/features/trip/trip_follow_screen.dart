import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/ride_repository.dart';
import '../ride_request/widgets/trip_map.dart';

/// Read-only live view of a shared trip. Reached via a `sift://trip/<id>` deep
/// link — a trusted contact with Sift installed taps the shared link and
/// watches the driver move in real time. No controls, no money, no PII beyond
/// what the rider chose to share.
class TripFollowScreen extends ConsumerStatefulWidget {
  const TripFollowScreen({super.key, required this.rideId});
  final String rideId;

  @override
  ConsumerState<TripFollowScreen> createState() => _TripFollowScreenState();
}

class _TripFollowScreenState extends ConsumerState<TripFollowScreen> {
  StreamSubscription<Ride>? _sub;
  Ride? _ride;
  bool _error = false;

  bool get _signedIn => FirebaseAuth.instance.currentUser != null;

  @override
  void initState() {
    super.initState();
    if (_signedIn) {
      _sub = ref.read(rideRepositoryProvider).watch(widget.rideId).listen(
            (r) => setState(() => _ride = r),
            onError: (_) => setState(() => _error = true),
          );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  LatLng _targetFor(Ride r) =>
      r.status == RideStatus.inProgress ? r.destination : r.pickup;

  bool _isEnded(RideStatus s) =>
      s == RideStatus.completed ||
      s == RideStatus.cancelled ||
      s == RideStatus.expired;

  @override
  Widget build(BuildContext context) {
    final ride = _ride;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          if (!_signedIn)
            _message(
              icon: Icons.lock_outline,
              title: 'Sign in to follow this trip',
              body: 'Open Sift and sign in, then tap the shared link again to '
                  'watch the trip live.',
              actionLabel: 'Open Sift',
              onAction: () => context.go(AppRouter.splash),
            )
          else if (_error)
            _message(
              icon: Icons.link_off,
              title: 'Trip unavailable',
              body: 'This trip link is invalid or the trip is no longer being '
                  'shared.',
            )
          else if (ride == null)
            const Center(
                child: CircularProgressIndicator(color: AppColors.green))
          else ...[
            Positioned.fill(
              child: TripMap(
                driver: ride.driverPos,
                target: _targetFor(ride),
                route: const [],
                heading: ride.driverHeading,
                targetIsDestination: ride.status == RideStatus.inProgress,
                stops: ride.status == RideStatus.inProgress
                    ? ride.stops.map((s) => s.latLng).toList()
                    : const [],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => context.canPop()
                          ? context.pop()
                          : context.go(AppRouter.splash),
                      child: const SizedBox(
                          width: 46,
                          height: 46,
                          child:
                              Icon(Icons.arrow_back, color: AppColors.dark)),
                    ),
                  ),
                ),
              ),
            ),
            Align(
                alignment: Alignment.bottomCenter, child: _statusSheet(ride)),
          ],
        ],
      ),
    );
  }

  Widget _statusSheet(Ride r) {
    final ended = _isEnded(r.status);
    final headline = switch (r.status) {
      RideStatus.accepted => 'Driver is on the way to the pickup',
      RideStatus.arriving => 'Driver is arriving',
      RideStatus.arrived => 'Driver has arrived',
      RideStatus.inProgress => 'On the trip to ${r.destinationLabel}',
      RideStatus.completed => 'Trip completed',
      RideStatus.cancelled => 'Trip cancelled',
      RideStatus.expired => 'Trip ended',
      RideStatus.requested => 'Finding a driver',
      RideStatus.scheduled => 'Scheduled',
    };
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(ended ? Icons.flag : Icons.shield_outlined,
                      color: AppColors.green, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(headline,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.field,
                    child:
                        Icon(Icons.person, color: AppColors.muted, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.driverName ?? 'Driver',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        Text(r.driverVehicle ?? 'Vehicle',
                            style: const TextStyle(color: AppColors.muted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text('You are following this trip live on Sift.',
                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message({
    required IconData icon,
    required String title,
    required String body,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.muted),
            const SizedBox(height: 18),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, height: 1.5)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: onAction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26)),
                  ),
                  child: Text(actionLabel,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
