import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/map_style.dart';
import '../../data/models/parcel.dart';
import '../../data/repositories/parcel_repository.dart';
import 'pod_capture_sheet.dart';

/// Driver's parcel job: navigate to pickup → collect → work through each
/// drop-off (navigate, capture POD or mark failed) → settled on the last stop.
class ParcelDeliveryScreen extends ConsumerStatefulWidget {
  const ParcelDeliveryScreen({super.key, required this.parcelId});
  final String parcelId;

  @override
  ConsumerState<ParcelDeliveryScreen> createState() =>
      _ParcelDeliveryScreenState();
}

class _ParcelDeliveryScreenState extends ConsumerState<ParcelDeliveryScreen> {
  StreamSubscription<Parcel>? _sub;
  StreamSubscription<Position>? _posSub;
  Parcel? _parcel;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(parcelRepositoryProvider);
    _sub = repo.watch(widget.parcelId).listen((p) {
      setState(() => _parcel = p);
      if (p.status == ParcelStatus.completed ||
          p.status == ParcelStatus.cancelled) {
        // Job's done — let the driver review the final sheet, no auto-pop.
      }
    });
    // Mirror live position into the parcel so the sender can track.
    _posSub = Geolocator.getPositionStream(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20),
    ).listen((pos) {
      repo.updateDriverTelemetry(widget.parcelId,
          lat: pos.latitude, lng: pos.longitude, heading: pos.heading);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _navigateTo(LatLng dest) async {
    final native = Uri.parse('google.navigation:q=${dest.latitude},${dest.longitude}');
    if (await launchUrl(native, mode: LaunchMode.externalApplication)) return;
    await launchUrl(
      Uri.parse('https://www.google.com/maps/dir/?api=1'
          '&destination=${dest.latitude},${dest.longitude}'),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _pickUp() async {
    setState(() => _busy = true);
    try {
      await ref.read(parcelRepositoryProvider).markPickedUp(widget.parcelId);
    } catch (_) {} finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deliver(Parcel p, int stopIndex) async {
    final stop = p.stops[stopIndex];
    final pod = await capturePod(
      context,
      ref,
      parcelId: p.id,
      stopIndex: stopIndex,
      defaultName: stop.recipientName,
    );
    if (pod == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(parcelRepositoryProvider).deliverStop(
            p.id,
            stopIndex,
            podPhotoUrl: pod.photoUrl,
            podSignatureUrl: pod.signatureUrl,
            receivedBy: pod.receivedBy,
          );
    } catch (_) {} finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fail(Parcel p, int stopIndex) async {
    final reason = await _askFailReason();
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(parcelRepositoryProvider).failStop(p.id, stopIndex, reason);
    } catch (_) {} finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askFailReason() {
    const reasons = [
      'Recipient unavailable',
      'Wrong address',
      'Recipient refused',
      'Could not access location',
    ];
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Why did the delivery fail?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            ...reasons.map((r) => ListTile(
                  title: Text(r),
                  onTap: () => Navigator.pop(ctx, r),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _parcel;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned.fill(child: _map(p)),
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
    }
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: pickup, zoom: 13),
      style: kDarkMapStyle,
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: false,
      markers: markers,
    );
  }

  Widget _sheet(Parcel p) {
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
          child: _body(p),
        ),
      ),
    );
  }

  Widget _body(Parcel p) {
    // Pre-pickup: head to the sender, collect the parcel.
    if (p.status == ParcelStatus.accepted ||
        p.status == ParcelStatus.arriving) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Collect the parcel',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(p.pickupAddress, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 6),
          Text('${p.stops.length} drop-off${p.stops.length == 1 ? '' : 's'} · R${p.displayFare.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _navButton(() => _navigateTo(p.pickup))),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _primary(
                    _busy ? 'Working…' : 'Mark picked up', _busy ? null : _pickUp),
              ),
            ],
          ),
        ],
      );
    }

    // Completed / ended.
    if (p.status == ParcelStatus.completed ||
        p.status == ParcelStatus.cancelled ||
        p.status == ParcelStatus.expired) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
              p.status == ParcelStatus.completed
                  ? Icons.check_circle
                  : Icons.info_outline,
              color: AppColors.green,
              size: 40),
          const SizedBox(height: 8),
          Text(
              p.status == ParcelStatus.completed
                  ? 'All drop-offs done'
                  : 'Parcel ended',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${p.deliveredCount} delivered · ${p.failedCount} failed',
              style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 14),
          _primary('Done', () => context.go(AppRouter.driverHome)),
        ],
      );
    }

    // Delivering: work the active drop-off.
    final stop = p.activeStop;
    final idx = p.stops.indexWhere((s) => !s.isResolved);
    if (stop == null || idx < 0) {
      return _primary('Finishing…', null);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Drop-off ${idx + 1} of ${p.stops.length}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Text('${p.deliveredCount}/${p.stops.length} done',
                style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          ],
        ),
        const SizedBox(height: 8),
        Text(stop.recipientName,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        Text(stop.address, style: const TextStyle(color: AppColors.muted)),
        if (stop.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Note: ${stop.note}',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.muted, fontStyle: FontStyle.italic)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (stop.recipientPhone.isNotEmpty)
              IconButton(
                onPressed: () =>
                    launchUrl(Uri(scheme: 'tel', path: stop.recipientPhone)),
                icon: const Icon(Icons.call, color: AppColors.green),
              ),
            Expanded(child: _navButton(() => _navigateTo(stop.location))),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _fail(p, idx),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE0524D),
                  side: const BorderSide(color: Color(0xFFE0524D)),
                  minimumSize: const Size(0, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                ),
                child: const Text('Failed',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: _primary(_busy ? 'Saving…' : 'Delivered + POD',
                  _busy ? null : () => _deliver(p, idx)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _navButton(VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.navigation_outlined),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.green,
        side: const BorderSide(color: AppColors.selectedBorder),
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      label: const Text('Navigate', style: TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _primary(String label, VoidCallback? onTap) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green,
          disabledBackgroundColor: AppColors.green.withValues(alpha: .4),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
