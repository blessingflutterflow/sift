import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/map_style.dart';
import '../../data/models/parcel.dart';
import '../../data/repositories/parcel_repository.dart';
import '../auth/session_controller.dart';
import 'address_search_sheet.dart';
import 'parcel_fare.dart';
import 'parcel_request_controller.dart';
import 'stop_editor_sheet.dart';

/// Customer "send a parcel" flow — pickup + one or more drop-offs (multi-stop),
/// each with a recipient and size, a live fare estimate, then send.
class SendParcelScreen extends ConsumerStatefulWidget {
  const SendParcelScreen({super.key});

  @override
  ConsumerState<SendParcelScreen> createState() => _SendParcelScreenState();
}

class _SendParcelScreenState extends ConsumerState<SendParcelScreen> {
  GoogleMapController? _map;
  String _payMethod = 'cash';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(parcelRequestProvider.notifier).loadPickup());
  }

  Future<void> _editPickup() async {
    final picked = await showAddressSearch(context, ref, title: 'Pickup address');
    if (picked != null) {
      ref.read(parcelRequestProvider.notifier).setPickup(
          picked.location, picked.address);
    }
  }

  Future<void> _addStop() async {
    final stop = await showStopEditor(context, ref);
    if (stop != null) ref.read(parcelRequestProvider.notifier).addStop(stop);
  }

  Future<void> _editStop(int i, ParcelStop existing) async {
    final stop = await showStopEditor(context, ref, existing: existing);
    if (stop != null) {
      ref.read(parcelRequestProvider.notifier).updateStop(i, stop);
    }
  }

  Future<void> _send() async {
    final s = ref.read(parcelRequestProvider);
    final session = ref.read(sessionProvider);
    if (!s.ready || session.uid == null) return;

    setState(() => _sending = true);
    try {
      final data = Parcel.newRequest(
        senderId: session.uid!,
        senderName: session.name,
        senderPhone: session.phone,
        pickup: s.pickup!,
        pickupAddress: s.pickupAddress,
        stops: s.stops,
        distanceKm: s.distanceKm,
        fare: ParcelFare.estimate(s.distanceKm, s.stops),
        paymentMethod: _payMethod,
      );
      final id = await ref.read(parcelRepositoryProvider).createRequest(data);
      ref.read(parcelRequestProvider.notifier).reset();
      if (mounted) context.go(AppRouter.parcelTracking, extra: id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not send the parcel. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _fit(ParcelRequestState s) {
    if (_map == null || s.pickup == null) return;
    final pts = [s.pickup!, ...s.stops.map((e) => e.location)];
    if (pts.length < 2) {
      _map!.animateCamera(CameraUpdate.newLatLngZoom(s.pickup!, 13));
      return;
    }
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = p.latitude < minLat ? p.latitude : minLat;
      maxLat = p.latitude > maxLat ? p.latitude : maxLat;
      minLng = p.longitude < minLng ? p.longitude : minLng;
      maxLng = p.longitude > maxLng ? p.longitude : maxLng;
    }
    _map!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      ),
      70,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(parcelRequestProvider);
    final fare = ParcelFare.estimate(s.distanceKm, s.stops);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit(s));

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    onPressed: () => context.pop(),
                  ),
                  const Text('Send a parcel',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            // Map
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.30,
              child: GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: s.pickup ?? const LatLng(-26.2041, 28.0473),
                  zoom: 12,
                ),
                style: kDarkMapStyle,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                compassEnabled: false,
                markers: _markers(s),
                polylines: {
                  if (s.routePoints.length >= 2)
                    Polyline(
                      polylineId: const PolylineId('route'),
                      points: s.routePoints,
                      color: AppColors.green,
                      width: 4,
                    ),
                },
                onMapCreated: (c) => _map = c,
              ),
            ),
            // Form
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                children: [
                  _pickupRow(s),
                  const SizedBox(height: 12),
                  const Text('Drop-offs',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted)),
                  const SizedBox(height: 6),
                  for (var i = 0; i < s.stops.length; i++) _stopRow(i, s.stops[i]),
                  _addStopButton(),
                  const SizedBox(height: 16),
                  _paymentSelector(),
                ],
              ),
            ),
            _bottomBar(s, fare),
          ],
        ),
      ),
    );
  }

  Set<Marker> _markers(ParcelRequestState s) {
    final markers = <Marker>{};
    if (s.pickup != null) {
      markers.add(Marker(
        markerId: const MarkerId('pickup'),
        position: s.pickup!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: const InfoWindow(title: 'Pickup'),
      ));
    }
    for (var i = 0; i < s.stops.length; i++) {
      markers.add(Marker(
        markerId: MarkerId('stop$i'),
        position: s.stops[i].location,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: 'Drop-off ${i + 1}'),
      ));
    }
    return markers;
  }

  Widget _pickupRow(ParcelRequestState s) {
    return InkWell(
      onTap: _editPickup,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.trip_origin, color: AppColors.green, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Pickup',
                      style: TextStyle(fontSize: 12, color: AppColors.muted)),
                  Text(s.pickupAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const Icon(Icons.edit_outlined, size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }

  Widget _stopRow(int i, ParcelStop stop) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.selectedFill,
            child: Text('${i + 1}',
                style: const TextStyle(
                    color: AppColors.green,
                    fontWeight: FontWeight.w800,
                    fontSize: 13)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stop.recipientName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${stop.address} · ${ParcelSize.fromName(stop.size).label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 12, color: AppColors.muted)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: AppColors.muted,
            onPressed: () => _editStop(i, stop),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: AppColors.muted,
            onPressed: () =>
                ref.read(parcelRequestProvider.notifier).removeStop(i),
          ),
        ],
      ),
    );
  }

  Widget _addStopButton() {
    return OutlinedButton.icon(
      onPressed: _addStop,
      icon: const Icon(Icons.add),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.green,
        side: const BorderSide(color: AppColors.selectedBorder),
        minimumSize: const Size(double.infinity, 48),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      label: const Text('Add a drop-off',
          style: TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _paymentSelector() {
    Widget chip(String value, IconData icon, String label) {
      final on = _payMethod == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _payMethod = value),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: on ? AppColors.selectedFill : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: on ? AppColors.selectedBorder : AppColors.line,
                  width: on ? 1.5 : 1),
            ),
            child: Column(
              children: [
                Icon(icon,
                    color: on ? AppColors.green : AppColors.muted, size: 22),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: on ? AppColors.green : AppColors.muted)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('cash', Icons.payments_outlined, 'Cash'),
        chip('card', Icons.credit_card, 'Card'),
        chip('wallet', Icons.account_balance_wallet_outlined, 'Wallet'),
      ],
    );
  }

  Widget _bottomBar(ParcelRequestState s, double fare) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -3)),
        ],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('R${fare.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w900)),
              Text(
                  s.stops.isEmpty
                      ? 'Add a drop-off'
                      : '${s.stops.length} stop${s.stops.length == 1 ? '' : 's'} · ${s.distanceKm.toStringAsFixed(1)} km',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: (s.ready && !_sending) ? _send : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.green,
                disabledBackgroundColor: AppColors.green.withValues(alpha: .4),
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26)),
              ),
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white))
                  : const Text('Send parcel',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}
