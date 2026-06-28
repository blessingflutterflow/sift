import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/places_repository.dart';
import '../../data/repositories/ride_repository.dart';
import '../../data/services/notification_service.dart';
import '../auth/account_menu.dart';
import '../auth/session_controller.dart';
import '../ride_request/ride_request_controller.dart';

/// Home — Screen 19, refined.
///
/// Intent: show the user where they are and let them start a trip by
/// searching a destination or tapping a saved place. The map centers on
/// the user's real GPS position; the bottom sheet is draggable.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  GoogleMapController? _controller;
  bool _showSafety = true;

  static const CameraPosition _fallback = CameraPosition(
    target: LatLng(-26.2041, 28.0473), // Johannesburg
    zoom: 15,
  );

  @override
  void initState() {
    super.initState();
    _centerOnCurrentPosition();
    // Idempotent: stores this device's FCM token for trip-status pushes.
    final uid = ref.read(sessionProvider).uid;
    if (uid != null) {
      ref.read(notificationServiceProvider).register(uid);
    }
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
    } catch (_) {
      // Stay on fallback if location is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    const sheetMin = 0.40;

    return Scaffold(
      body: Stack(
        children: [
          // Live map
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _fallback,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              padding: EdgeInsets.only(bottom: size.height * sheetMin),
              onMapCreated: (c) {
                _controller = c;
                _centerOnCurrentPosition();
              },
            ),
          ),

          // Menu + recenter controls, kept clear of the notch.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _circleButton(
                    icon: Icons.menu,
                    onTap: () => showAccountMenu(context, ref),
                  ),
                ],
              ),
            ),
          ),

          // Recenter button, floating just above the sheet.
          Positioned(
            right: 16,
            bottom: size.height * sheetMin + 16,
            child: _circleButton(
              icon: Icons.my_location,
              onTap: _centerOnCurrentPosition,
            ),
          ),

          // Safety toolkit card, above the sheet, dismissible.
          if (_showSafety)
            Positioned(
              left: 16,
              right: 16,
              bottom: size.height * sheetMin + 84,
              child: _safetyCard(),
            ),

          // Draggable destination sheet.
          DraggableScrollableSheet(
            initialChildSize: sheetMin,
            minChildSize: sheetMin,
            maxChildSize: 0.92,
            builder: (context, scrollController) => _searchSheet(scrollController),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Icon(icon, size: 24, color: AppColors.dark),
        ),
      ),
    );
  }

  Widget _safetyCard() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      shadowColor: Colors.black26,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: AppColors.green,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.shield_outlined,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Safety Toolkit',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  SizedBox(height: 2),
                  Text('Learn more about our safety features',
                      style: TextStyle(fontSize: 13, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 22, color: Color(0xFF999999)),
              onPressed: () => setState(() => _showSafety = false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchSheet(ScrollController scrollController) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Color(0x22000000), blurRadius: 25, offset: Offset(0, -5)),
        ],
      ),
      child: ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          // Grab handle
          Center(
            child: Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(top: 12, bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFE6E6E8),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          // Search field
          GestureDetector(
            onTap: () => context.push(AppRouter.destination),
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.field,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.search, size: 24, color: AppColors.dark),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Where to?',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  Icon(Icons.schedule, size: 22, color: AppColors.muted),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Send a parcel
          GestureDetector(
            onTap: () => context.push(AppRouter.sendParcel),
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.selectedFill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.local_shipping_outlined,
                      size: 24, color: AppColors.green),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Send a parcel',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppColors.green)),
                  ),
                  Icon(Icons.chevron_right, size: 22, color: AppColors.green),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ..._quickPlaces(),
        ],
      ),
    );
  }

  /// Saved places (Home/Work/customs) + recent destinations — the rows under
  /// the search field. Falls back to a "set up saved places" hint when empty.
  List<Widget> _quickPlaces() {
    final uid = ref.watch(sessionProvider).uid;
    if (uid == null) return const [];
    return [
      StreamBuilder<List<SavedPlace>>(
        stream: ref.read(placesRepositoryProvider).watch(uid),
        builder: (context, snap) {
          final places = snap.data ?? const <SavedPlace>[];
          return Column(
            children: [
              for (final p in places.take(4))
                _place(
                  p.slot == 'home'
                      ? Icons.home_outlined
                      : p.slot == 'work'
                          ? Icons.work_outline
                          : Icons.star_border,
                  p.label,
                  p.address,
                  () => _startTo(p.latLng, p.label),
                ),
              if (places.isEmpty)
                _place(Icons.add_location_alt_outlined, 'Add Home or Work',
                    'One-tap rides to your usual places', () async {
                  await context.push(AppRouter.savedPlaces);
                }),
            ],
          );
        },
      ),
      StreamBuilder<List<Ride>>(
        stream: ref.read(rideRepositoryProvider).historyForRider(uid),
        builder: (context, snap) {
          final rides = snap.data ?? const <Ride>[];
          final seen = <String>{};
          final recents = <Ride>[];
          for (final r in rides) {
            if (r.status != RideStatus.completed) continue;
            if (r.destinationLabel.isEmpty) continue;
            if (seen.add(r.destinationLabel)) recents.add(r);
            if (recents.length >= 3) break;
          }
          return Column(
            children: [
              for (final r in recents)
                _place(Icons.history, r.destinationLabel, 'Recent trip',
                    () => _startTo(r.destination, r.destinationLabel)),
            ],
          );
        },
      ),
    ];
  }

  /// Start the request flow straight from a quick place: load pickup (GPS),
  /// then jump to the searching transition with the destination preset.
  Future<void> _startTo(LatLng coords, String label) async {
    await ref.read(rideRequestProvider.notifier).loadPickup();
    if (!mounted) return;
    context.push(AppRouter.searching, extra: {
      'lat': coords.latitude,
      'lng': coords.longitude,
      'label': label,
    });
  }

  Widget _place(
      IconData icon, String name, String address, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24, color: const Color(0xFF7A7C86)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(address,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
