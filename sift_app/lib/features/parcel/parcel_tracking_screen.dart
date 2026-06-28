import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/map_style.dart';
import '../../data/models/parcel.dart';
import '../../data/repositories/parcel_repository.dart';

/// Sender's live view of a parcel: dispatch → driver assigned → picked up →
/// per-stop delivery progress → completed (with POD).
class ParcelTrackingScreen extends ConsumerStatefulWidget {
  const ParcelTrackingScreen({super.key, required this.parcelId});
  final String parcelId;

  @override
  ConsumerState<ParcelTrackingScreen> createState() =>
      _ParcelTrackingScreenState();
}

class _ParcelTrackingScreenState extends ConsumerState<ParcelTrackingScreen> {
  StreamSubscription<Parcel>? _sub;
  Parcel? _parcel;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(parcelRepositoryProvider)
        .watch(widget.parcelId)
        .listen((p) => setState(() => _parcel = p));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _cancel() async {
    try {
      await ref.read(parcelRepositoryProvider).cancel(widget.parcelId);
    } catch (_) {}
    if (mounted) context.go(AppRouter.home);
  }

  String _statusLine(Parcel p) {
    switch (p.status) {
      case ParcelStatus.requested:
        return 'Finding a driver for your parcel…';
      case ParcelStatus.accepted:
      case ParcelStatus.arriving:
        return '${p.driverName ?? 'Driver'} is heading to the pickup';
      case ParcelStatus.pickedUp:
      case ParcelStatus.delivering:
        return 'Delivering · ${p.deliveredCount}/${p.stops.length} drop-offs done';
      case ParcelStatus.completed:
        return 'All deliveries complete';
      case ParcelStatus.cancelled:
        return 'Parcel cancelled';
      case ParcelStatus.expired:
        return 'No drivers available right now';
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _parcel;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned.fill(child: _map(p)),
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
                    onTap: () => context.go(AppRouter.home),
                    child: const SizedBox(
                        width: 46,
                        height: 46,
                        child: Icon(Icons.arrow_back, color: AppColors.dark)),
                  ),
                ),
              ),
            ),
          ),
          if (p != null)
            Align(alignment: Alignment.bottomCenter, child: _sheet(p)),
        ],
      ),
    );
  }

  Widget _map(Parcel? p) {
    final pickup = p?.pickup ?? const LatLng(-26.2041, 28.0473);
    final markers = <Marker>{};
    if (p != null) {
      markers.add(Marker(
        markerId: const MarkerId('pickup'),
        position: p.pickup,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ));
      for (var i = 0; i < p.stops.length; i++) {
        markers.add(Marker(
          markerId: MarkerId('stop$i'),
          position: p.stops[i].location,
          icon: BitmapDescriptor.defaultMarkerWithHue(
              p.stops[i].status == 'delivered'
                  ? BitmapDescriptor.hueGreen
                  : p.stops[i].status == 'failed'
                      ? BitmapDescriptor.hueRed
                      : BitmapDescriptor.hueYellow),
        ));
      }
      final d = p.driverPos;
      if (d != null) {
        markers.add(Marker(
          markerId: const MarkerId('driver'),
          position: d,
          icon: BitmapDescriptor.defaultMarker,
        ));
      }
    }
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: pickup, zoom: 12.5),
      style: kDarkMapStyle,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: false,
      markers: markers,
    );
  }

  Widget _sheet(Parcel p) {
    final ended = p.status == ParcelStatus.completed ||
        p.status == ParcelStatus.cancelled ||
        p.status == ParcelStatus.expired;
    final canCancel = p.status == ParcelStatus.requested ||
        p.status == ParcelStatus.accepted ||
        p.status == ParcelStatus.arriving;

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
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(_statusLine(p),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                  Text('R${p.displayFare.toStringAsFixed(0)}',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800)),
                ],
              ),
              if (p.driverName != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: AppColors.field,
                      backgroundImage: (p.driverPhoto?.isNotEmpty ?? false)
                          ? NetworkImage(p.driverPhoto!)
                          : null,
                      child: (p.driverPhoto?.isNotEmpty ?? false)
                          ? null
                          : const Icon(Icons.person, color: AppColors.muted),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.driverName!,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          Text(p.driverVehicle ?? 'Vehicle',
                              style: const TextStyle(color: AppColors.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              // Per-stop progress
              ...List.generate(p.stops.length, (i) => _stopProgress(i, p.stops[i])),
              const SizedBox(height: 10),
              if (canCancel)
                Center(
                  child: TextButton(
                    onPressed: _cancel,
                    child: const Text('Cancel parcel',
                        style: TextStyle(color: AppColors.muted)),
                  ),
                ),
              if (ended)
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () => context.go(AppRouter.home),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25)),
                    ),
                    child: const Text('Done',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stopProgress(int i, ParcelStop s) {
    final (icon, color) = switch (s.status) {
      'delivered' => (Icons.check_circle, AppColors.green),
      'failed' => (Icons.cancel, const Color(0xFFE0524D)),
      _ => (Icons.radio_button_unchecked, AppColors.muted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${i + 1}. ${s.recipientName} · ${s.address}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          if (s.status == 'delivered' && s.podPhotoUrl != null)
            TextButton(
              onPressed: () => _viewPod(s),
              child: const Text('POD', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  void _viewPod(ParcelStop s) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Delivered to ${s.receivedBy ?? s.recipientName}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              if (s.podPhotoUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(s.podPhotoUrl!, height: 220, fit: BoxFit.cover),
                ),
              if (s.podSignatureUrl != null) ...[
                const SizedBox(height: 10),
                const Text('Signature',
                    style: TextStyle(fontSize: 12, color: AppColors.muted)),
                Image.network(s.podSignatureUrl!, height: 90, fit: BoxFit.contain),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
