import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import 'ride_request_controller.dart';

/// Screen 5116 — the transition. Shows the pickup pin while the map slowly
/// zooms out and the sheet shimmers, until the real route is ready.
class SearchingScreen extends ConsumerStatefulWidget {
  const SearchingScreen({super.key, required this.args});
  final Map<String, dynamic>? args;

  @override
  ConsumerState<SearchingScreen> createState() => _SearchingScreenState();
}

class _SearchingScreenState extends ConsumerState<SearchingScreen>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _map;
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  Timer? _zoomTimer;
  double _zoom = 16.5;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final started = DateTime.now();

    // Kick off the real destination resolve + route fetch.
    final notifier = ref.read(rideRequestProvider.notifier);
    final args = widget.args ?? {};
    final label = args['label'] as String? ?? 'Destination';
    final placeId = args['placeId'] as String?;
    final lat = args['lat'] as double?;
    final lng = args['lng'] as double?;

    if (placeId != null) {
      await notifier.chooseDestination(placeId, label);
    } else if (lat != null && lng != null) {
      await notifier.chooseDestinationCoords(LatLng(lat, lng), label);
    }

    // Hold for at least the zoom-out beat so the transition reads.
    final elapsed = DateTime.now().difference(started);
    final wait = const Duration(milliseconds: 1800) - elapsed;
    if (wait > Duration.zero) await Future.delayed(wait);

    if (mounted && !_advanced) {
      _advanced = true;
      context.pushReplacement(AppRouter.rideOptions);
    }
  }

  void _slowZoomOut() {
    _zoomTimer = Timer.periodic(const Duration(milliseconds: 70), (t) {
      if (_zoom <= 11.0 || _map == null) {
        t.cancel();
        return;
      }
      _zoom -= 0.18;
      _map?.moveCamera(CameraUpdate.zoomTo(_zoom));
    });
  }

  @override
  void dispose() {
    _zoomTimer?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pickup = ref.watch(rideRequestProvider).pickup ??
        const LatLng(-26.2041, 28.0473); // Johannesburg fallback

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: pickup, zoom: _zoom),
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              markers: {
                Marker(markerId: const MarkerId('pickup'), position: pickup),
              },
              onMapCreated: (c) {
                _map = c;
                _slowZoomOut();
              },
            ),
          ),

          // Back button
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topLeft,
                child: _circle(Icons.arrow_back, () => context.pop()),
              ),
            ),
          ),

          // Skeleton sheet
          Align(alignment: Alignment.bottomCenter, child: _skeletonSheet()),
        ],
      ),
    );
  }

  Widget _circle(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
            width: 46, height: 46, child: Icon(icon, color: AppColors.dark)),
      ),
    );
  }

  Widget _skeletonSheet() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      child: Column(
        children: [
          Row(
            children: [
              _bar(width: 200, height: 16),
              const Spacer(),
              const Icon(Icons.search, color: AppColors.muted),
            ],
          ),
          const SizedBox(height: 16),
          _bar(width: 160, height: 14),
          const SizedBox(height: 18),
          _bar(width: double.infinity, height: 44, radius: 12),
        ],
      ),
    );
  }

  Widget _bar({required double width, required double height, double radius = 8}) {
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, _) {
        final t = 0.35 + 0.25 * _shimmer.value;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Color.fromRGBO(228, 228, 232, t + 0.4),
            borderRadius: BorderRadius.circular(radius),
          ),
        );
      },
    );
  }
}
