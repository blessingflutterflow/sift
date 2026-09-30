import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/places_repository.dart';
import '../../data/repositories/ride_repository.dart';
import '../auth/session_controller.dart';
import 'ride_request_controller.dart';
import 'services/places_service.dart';

/// Screen 5115 — "Your route". Pickup is auto-filled from GPS; destination is
/// a live Google Places search (SA), with quick saved places below.
class DestinationScreen extends ConsumerStatefulWidget {
  const DestinationScreen({super.key});

  @override
  ConsumerState<DestinationScreen> createState() => _DestinationScreenState();
}


class _DestinationScreenState extends ConsumerState<DestinationScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<PlacePrediction> _predictions = [];
  // When true the search box is editing the PICKUP; otherwise the destination.
  bool _pickupMode = false;

  @override
  void initState() {
    super.initState();
    ref.read(rideRequestProvider.notifier).loadPickup();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    _debounce?.cancel();
    final q = _controller.text;
    if (q.trim().length < 2) {
      setState(() => _predictions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final preds = await ref.read(placesServiceProvider).autocomplete(q);
      if (mounted) setState(() => _predictions = preds);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _goToSearching({String? placeId, LatLng? coords, required String label}) {
    context.push(AppRouter.searching, extra: {
      'placeId': placeId,
      'lat': coords?.latitude,
      'lng': coords?.longitude,
      'label': label,
    });
  }

  void _enterPickupMode() {
    setState(() {
      _pickupMode = true;
      _controller.clear();
      _predictions = [];
    });
  }

  Future<void> _selectPickup({String? placeId, LatLng? coords, required String label}) async {
    final notifier = ref.read(rideRequestProvider.notifier);
    if (placeId != null) {
      await notifier.choosePickup(placeId, label);
    } else if (coords != null) {
      await notifier.choosePickupCoords(coords, label);
    }
    if (mounted) {
      setState(() {
        _pickupMode = false;
        _controller.clear();
        _predictions = [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pickup = ref.watch(rideRequestProvider).pickupAddress;
    final searching = _controller.text.trim().length >= 2;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, size: 24),
          onPressed: () => context.pop(),
        ),
        centerTitle: true,
        title: const Text('Your route',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.dark)),
        actions: [
          IconButton(icon: const Icon(Icons.add, size: 26), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              children: [
                _pickupMode ? _pickupField() : _pickupRow(pickup),
                const SizedBox(height: 12),
                _pickupMode ? _destinationStaticRow() : _destinationField(),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: searching ? _predictionList() : _savedList(),
          ),
        ],
      ),
    );
  }

  Widget _pickupRow(String address) {
    return GestureDetector(
      onTap: _enterPickupMode,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: const Color(0xFF4C56F4),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFC9CCFF), width: 4),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(address,
                  style: const TextStyle(fontSize: 17, color: AppColors.dark),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.edit_outlined, size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }

  /// Editable pickup search (mirrors the destination field) — lets the rider
  /// type a pickup instead of relying on GPS.
  Widget _pickupField() {
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 16, right: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF4C56F4), width: 2),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: const Color(0xFF4C56F4),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFC9CCFF), width: 4),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search pickup',
                hintStyle: TextStyle(color: AppColors.muted),
                border: InputBorder.none,
                isCollapsed: true,
              ),
              style: const TextStyle(fontSize: 17, color: AppColors.dark),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _pickupMode = false;
              _controller.clear();
              _predictions = [];
            }),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.muted)),
          ),
        ],
      ),
    );
  }

  /// While editing the pickup, the destination collapses to a static row the
  /// rider can tap to switch back to destination search.
  Widget _destinationStaticRow() {
    final label = ref.watch(rideRequestProvider).destinationLabel;
    return GestureDetector(
      onTap: () => setState(() {
        _pickupMode = false;
        _controller.clear();
        _predictions = [];
      }),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.search, size: 22, color: AppColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label.isEmpty ? 'Destination' : label,
                style: TextStyle(
                    fontSize: 17,
                    color: label.isEmpty ? AppColors.muted : AppColors.dark),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _destinationField() {
    return Container(
      height: 58,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.green, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 24, color: AppColors.dark),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Destination',
                hintStyle: TextStyle(color: AppColors.muted),
                border: InputBorder.none,
                isCollapsed: true,
              ),
              style: const TextStyle(fontSize: 18, color: AppColors.dark),
            ),
          ),
          GestureDetector(
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF4C56F4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Map',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.map_outlined, size: 22, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  /// Saved places + recent destinations shown before the user types.
  Widget _savedList() {
    final uid = ref.watch(sessionProvider).uid;
    if (uid == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        StreamBuilder<List<SavedPlace>>(
          stream: ref.read(placesRepositoryProvider).watch(uid),
          builder: (context, snap) {
            final places = snap.data ?? const <SavedPlace>[];
            return Column(
              children: [
                for (final p in places)
                  _row(
                    p.slot == 'home'
                        ? Icons.home_outlined
                        : p.slot == 'work'
                            ? Icons.work_outline
                            : Icons.star_border,
                    p.label,
                    p.address,
                    () => _goToSearching(coords: p.latLng, label: p.label),
                  ),
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
              if (recents.length >= 5) break;
            }
            return Column(
              children: [
                for (final r in recents)
                  _row(Icons.history, r.destinationLabel, 'Recent trip',
                      () => _goToSearching(
                          coords: r.destination, label: r.destinationLabel)),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _predictionList() {
    if (_predictions.isEmpty) {
      return const Center(
        child: Text('Searching…', style: TextStyle(color: AppColors.muted)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _predictions.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.line),
      itemBuilder: (context, i) {
        final p = _predictions[i];
        return _row(
          Icons.location_on_outlined,
          p.primary,
          p.secondary,
          _pickupMode
              ? () => _selectPickup(placeId: p.placeId, label: p.primary)
              : () => _goToSearching(placeId: p.placeId, label: p.primary),
        );
      },
    );
  }

  Widget _row(IconData icon, String name, String sub, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 26, color: const Color(0xFF7A7C86)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(fontSize: 18, color: AppColors.dark),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (sub.isNotEmpty)
                    Text(sub,
                        style: const TextStyle(fontSize: 14, color: AppColors.muted),
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
