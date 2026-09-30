import 'dart:async';

import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/map_style.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/payment_repository.dart';
import '../../data/repositories/ride_repository.dart';
import '../../data/repositories/surge_repository.dart';
import '../../data/repositories/wallet_repository.dart';
import '../auth/session_controller.dart';
import 'models/pricing_config.dart';
import 'models/ride_tier.dart';
import 'ride_request_controller.dart';
import 'services/places_service.dart';
import 'widgets/car_image.dart';
import 'widgets/map_markers.dart';

/// Screens 5118/5119 — ride options. Real route + real ZAR fares (R30 base +
/// R5/km, per-tier multiplier). Drag the sheet to see all 8 tiers.
class RideOptionsScreen extends ConsumerStatefulWidget {
  const RideOptionsScreen({super.key});

  @override
  ConsumerState<RideOptionsScreen> createState() => _RideOptionsScreenState();
}

class _RideOptionsScreenState extends ConsumerState<RideOptionsScreen> {
  GoogleMapController? _map;
  int _selected = 0;
  bool _requesting = false;

  /// 'cash', 'card' (default vaulted card), or 'wallet' (prepaid balance).
  String _payMethod = 'cash';
  PaymentMethod? _defaultCard;
  double _walletBalance = 0;

  /// Set when the rider books for later (advance booking, up to 7 days).
  DateTime? _scheduledFor;

  /// Surge multiplier for the pickup (1.0 = none). Previewed from admin config.
  double _surge = 1.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadDefaultCard();
    _loadWallet();
    _loadSurge();
  }

  Future<void> _loadSurge() async {
    final pickup = ref.read(rideRequestProvider).pickup;
    if (pickup == null) return;
    final surge = await ref
        .read(surgeRepositoryProvider)
        .surgeForPoint(pickup.latitude, pickup.longitude);
    if (mounted) setState(() => _surge = surge);
  }

  Future<void> _loadWallet() async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;
    final balance = await ref.read(walletRepositoryProvider).balance(uid);
    if (mounted) setState(() => _walletBalance = balance);
  }

  Future<void> _loadDefaultCard() async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;
    final methods =
        await ref.read(paymentRepositoryProvider).watchMethods(uid).first;
    if (!mounted) return;
    setState(() {
      _defaultCard = methods.where((m) => m.isDefault).firstOrNull ??
          methods.firstOrNull;
      // Card by default when one is vaulted — the Uber-like experience.
      if (_defaultCard != null) _payMethod = 'card';
    });
  }

  Future<void> _choosePayment() async {
    final card = _defaultCard;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text('Pay with',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.payments_outlined,
                  color: AppColors.green, size: 26),
              title: const Text('Cash',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Pay the driver directly'),
              trailing: _payMethod == 'cash'
                  ? const Icon(Icons.check_circle, color: AppColors.green)
                  : null,
              onTap: () => Navigator.pop(sheetContext, 'cash'),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined,
                  color: AppColors.dark, size: 26),
              title: Text('Wallet · R${_walletBalance.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Pay from your prepaid balance'),
              trailing: _payMethod == 'wallet'
                  ? const Icon(Icons.check_circle, color: AppColors.green)
                  : null,
              onTap: () => Navigator.pop(sheetContext, 'wallet'),
            ),
            if (card != null)
              ListTile(
                leading: const Icon(Icons.credit_card,
                    color: AppColors.dark, size: 26),
                title: Text(card.label,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Charged automatically after the trip'),
                trailing: _payMethod == 'card'
                    ? const Icon(Icons.check_circle, color: AppColors.green)
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'card'),
              )
            else
              ListTile(
                leading: const Icon(Icons.add_card,
                    color: AppColors.muted, size: 26),
                title: const Text('Add a card'),
                subtitle: const Text('Set up once, pay automatically'),
                onTap: () => Navigator.pop(sheetContext, 'add'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || chosen == null) return;
    if (chosen == 'add') {
      await context.push(AppRouter.payments);
      await _loadDefaultCard();
    } else {
      setState(() => _payMethod = chosen);
    }
  }

  @override
  void initState() {
    super.initState();
    MapMarkers.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Pick a future date + time (15 min to 7 days out) for an advance booking.
  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final initial = _scheduledFor ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 7)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final chosen =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (chosen.isBefore(now.add(const Duration(minutes: 15)))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Pick a time at least 15 minutes from now.')));
      return;
    }
    setState(() => _scheduledFor = chosen);
  }

  String _fmtSchedule(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]}, $h:$m';
  }

  /// Rider-facing price confirmation. Shows the current estimated fare and
  /// makes the rider tap "Confirm & request" before anything is booked, so the
  /// price they agree to is always the live, admin-driven one.
  Future<bool?> _confirmFare({
    required RideTier tier,
    required double km,
    required double fare,
  }) {
    final scheduled = _scheduledFor != null;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE6E6E8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(scheduled ? 'Confirm your booking' : 'Confirm your trip',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 18),
              _confirmRow('Ride', tier.name),
              _confirmRow('Distance', '${km.toStringAsFixed(1)} km'),
              if (ref.read(rideRequestProvider).stops.isNotEmpty)
                _confirmRow('Stops',
                    '${ref.read(rideRequestProvider).stops.length}'),
              if (_surge > 1.0)
                _confirmRow('Surge',
                    '${_surge.toStringAsFixed(_surge % 1 == 0 ? 0 : 1)}×'),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1, color: Color(0xFFEDEDEF)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Estimated fare',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text('R${fare.round()}',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.green)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Final fare is confirmed at drop-off from the actual route.',
                style: TextStyle(fontSize: 12.5, color: AppColors.muted),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 54,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27)),
                  ),
                  child: Text(scheduled ? 'Confirm booking' : 'Confirm & request',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.muted)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 15, color: AppColors.muted)),
          Text(value,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  /// Create the ride request and head to matching — or, for an advance
  /// booking, create a scheduled ride (dispatched later) and return home.
  Future<void> _requestRide() async {
    final s = ref.read(rideRequestProvider);
    final session = ref.read(sessionProvider);
    final tier = kRideTiers[_selected];

    if (session.uid == null || s.pickup == null || s.destination == null) {
      context.push(AppRouter.matching, extra: null); // graceful fallback
      return;
    }

    // Fare from the live admin pricing config (same source the server charges
    // from), scaled by any active surge.
    final pricing =
        ref.read(pricingConfigProvider).value ?? PricingConfig.fallback;
    final fare = tier.fareValue(s.distanceKm, pricing) * _surge;

    // Price confirmation: the rider explicitly agrees to the current fare
    // before the request goes out.
    final confirmed = await _confirmFare(tier: tier, km: s.distanceKm, fare: fare);
    if (confirmed != true) return;

    setState(() => _requesting = true);
    final repo = ref.read(rideRepositoryProvider);
    final data = Ride.newRequest(
      riderId: session.uid!,
      riderName: session.name,
      riderPhone: session.phone,
      pickup: s.pickup!,
      pickupAddress: s.pickupAddress,
      destination: s.destination!,
      destinationLabel: s.destinationLabel,
      tierId: tier.id,
      tierName: tier.name,
      fare: fare,
      distanceKm: s.distanceKm,
      stops: s.stops,
      paymentMethod: _payMethod,
      scheduledFor: _scheduledFor,
    );
    try {
      if (_scheduledFor != null) {
        await repo.createRequest(data);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text('Ride scheduled for ${_fmtSchedule(_scheduledFor!)}')));
          context.go(AppRouter.home);
        }
        return;
      }
      final active = await repo.activeRideForRider(session.uid!);
      final rideId = active?.id ?? await repo.createRequest(data);
      if (mounted) context.push(AppRouter.matching, extra: rideId);
    } on FirebaseException catch (e) {
      // The rides-create rule refuses a blocked rider → permission-denied. Tell
      // them plainly instead of the generic "try again".
      if (mounted) {
        final blocked = e.code == 'permission-denied';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(blocked
              ? 'Your account has been blocked. Please contact support.'
              : 'Could not request ride. Try again.'),
          backgroundColor: blocked ? const Color(0xFFE0524D) : null,
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not request ride. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  void _fitRoute(RideRequestState s) {
    if (_map == null || s.pickup == null || s.destination == null) return;
    // Fit every point on the trip: pickup, each stop, and the destination.
    final pts = <LatLng>[
      s.pickup!,
      ...s.stops.map((e) => e.latLng),
      s.destination!,
    ];
    var minLat = pts.first.latitude, maxLat = pts.first.latitude;
    var minLng = pts.first.longitude, maxLng = pts.first.longitude;
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
      80,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(rideRequestProvider);
    final size = MediaQuery.sizeOf(context);
    const sheetMin = 0.46;
    final km = s.distanceKm;
    // Live admin pricing — the tile prices below update when admin changes it.
    final pricing = ref.watch(pricingConfigProvider).value ?? PricingConfig.fallback;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: s.pickup ?? const LatLng(-26.2041, 28.0473),
                zoom: 12,
              ),
              style: kDarkMapStyle,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              padding: EdgeInsets.only(bottom: size.height * sheetMin),
              markers: {
                if (s.pickup != null)
                  Marker(
                    markerId: const MarkerId('pickup'),
                    position: s.pickup!,
                    icon: MapMarkers.person ?? BitmapDescriptor.defaultMarker,
                    anchor: const Offset(0.5, 0.9),
                  ),
                for (int i = 0; i < s.stops.length; i++)
                  Marker(
                    markerId: MarkerId('stop_$i'),
                    position: s.stops[i].latLng,
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueOrange),
                    infoWindow: InfoWindow(title: 'Stop ${i + 1}'),
                  ),
                if (s.destination != null)
                  Marker(
                    markerId: const MarkerId('dest'),
                    position: s.destination!,
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueGreen),
                  ),
              },
              polylines: {
                if (s.hasRoute)
                  Polyline(
                    polylineId: const PolylineId('route'),
                    points: s.route!.points,
                    color: AppColors.green,
                    width: 4,
                    startCap: Cap.roundCap,
                    endCap: Cap.roundCap,
                  ),
              },
              onMapCreated: (c) {
                _map = c;
                Future.delayed(
                    const Duration(milliseconds: 250), () => _fitRoute(s));
              },
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: _topBar(s.destinationLabel),
            ),
          ),

          DraggableScrollableSheet(
            initialChildSize: sheetMin,
            minChildSize: sheetMin,
            maxChildSize: 0.92,
            builder: (context, scroll) => _sheet(scroll, km, pricing),
          ),
        ],
      ),
    );
  }

  Widget _topBar(String destination) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      shadowColor: Colors.black26,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 20),
              onPressed: () => context.pop(),
            ),
            Expanded(
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.sheetField,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(destination.isEmpty ? 'Destination' : destination,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ),
            IconButton(
                icon: const Icon(Icons.add, size: 26), onPressed: _addStop),
          ],
        ),
      ),
    );
  }

  /// List of chosen stops (each removable) — shown in the options sheet so the
  /// rider sees the whole trip and the fare updates as stops change.
  Widget _stopsSection() {
    final stops = ref.watch(rideRequestProvider).stops;
    if (stops.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        children: [
          for (int i = 0; i < stops.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                        color: Color(0xFFFF6B2C), shape: BoxShape.circle),
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(stops[i].label,
                        style: const TextStyle(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: AppColors.muted,
                    onPressed: () =>
                        ref.read(rideRequestProvider.notifier).removeStop(i),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Open a place search to add an intermediate stop (pickup → stops → dest).
  Future<void> _addStop() async {
    final s = ref.read(rideRequestProvider);
    if (!s.canAddStop) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('You can add up to $kMaxRideStops stops.')));
      return;
    }
    final picked = await showModalBottomSheet<PlacePrediction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _StopSearchSheet(),
    );
    if (picked == null) return;
    await ref
        .read(rideRequestProvider.notifier)
        .addStop(picked.placeId, picked.primary);
  }

  Widget _sheet(ScrollController scroll, double km, PricingConfig cfg) {
    final tier = kRideTiers[_selected];
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Color(0x22000000), blurRadius: 25, offset: Offset(0, -5)),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 5,
            margin: const EdgeInsets.only(top: 12, bottom: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE6E6E8),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          if (km > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Row(
                children: [
                  const Icon(Icons.straighten, size: 16, color: AppColors.muted),
                  const SizedBox(width: 6),
                  Text('${km.toStringAsFixed(1)} km trip',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.muted)),
                ],
              ),
            ),
          _stopsSection(),
          if (_surge > 1.0) _surgeBadge(),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: kRideTiers.length,
              itemBuilder: (context, i) => _tile(i, km, cfg),
            ),
          ),
          _payRow(),
          _cta(tier.name),
        ],
      ),
    );
  }

  Widget _surgeBadge() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.selectedFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.selectedBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt, color: AppColors.green, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${_surge.toStringAsFixed(_surge % 1 == 0 ? 0 : 1)}× surge — higher demand right now',
              style: const TextStyle(
                  color: AppColors.selectedBorder,
                  fontWeight: FontWeight.w700,
                  fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(int i, double km, PricingConfig cfg) {
    final t = kRideTiers[i];
    final selected = _selected == i;
    return GestureDetector(
      onTap: () => setState(() => _selected = i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 74,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.selectedFill : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.selectedBorder : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            _carIcon(t),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.name,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800)),
                  Text('${t.etaMin} min  ·  ${t.seatsLabel}',
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF73757F))),
                ],
              ),
            ),
            Text('R${(t.fareValue(km, cfg) * _surge).round()}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  // Placeholder car icon (swapped for PNG art when assets arrive).
  Widget _carIcon(RideTier t) {
    return CarImage(
      tierId: t.id,
      fallbackIcon: t.icon,
      badge: t.badge,
      size: 52,
    );
  }

  Widget _payRow() {
    final card = _defaultCard;
    final usingCard = _payMethod == 'card' && card != null;
    final usingWallet = _payMethod == 'wallet';
    final IconData icon = usingWallet
        ? Icons.account_balance_wallet_outlined
        : usingCard
            ? Icons.credit_card
            : Icons.payments_outlined;
    final title = usingWallet
        ? 'Wallet · R${_walletBalance.toStringAsFixed(2)}'
        : usingCard
            ? card.label
            : 'Cash';
    final subtitle = usingWallet
        ? 'Paid from your Sift wallet'
        : usingCard
            ? 'Charged automatically after the trip'
            : 'Pay the driver directly';
    return InkWell(
      onTap: _choosePayment,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFF1F1F1))),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: (usingCard || usingWallet) ? AppColors.dark : AppColors.green,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.muted)),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, color: AppColors.muted),
          ],
        ),
      ),
    );
  }

  Widget _cta(String tierName) {
    final scheduled = _scheduledFor != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Chosen schedule banner with a clear button.
            if (scheduled)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, size: 18, color: AppColors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Scheduled for ${_fmtSchedule(_scheduledFor!)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.dark)),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _scheduledFor = null),
                      child: const Text('Clear',
                          style: TextStyle(
                              color: AppColors.muted,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _requesting ? null : _requestRide,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.green,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28)),
                      ),
                      child: _requesting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white),
                            )
                          : Text(
                              scheduled
                                  ? 'Schedule $tierName'
                                  : 'Select $tierName',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Schedule for later.
                GestureDetector(
                  onTap: _pickSchedule,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheduled ? AppColors.dark : AppColors.green,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.schedule, color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-sheet place search for adding a stop. Returns the chosen prediction.
class _StopSearchSheet extends ConsumerStatefulWidget {
  const _StopSearchSheet();

  @override
  ConsumerState<_StopSearchSheet> createState() => _StopSearchSheetState();
}

class _StopSearchSheetState extends ConsumerState<_StopSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<PlacePrediction> _predictions = [];

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 14,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add a stop',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 22, color: AppColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search stop',
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _predictions.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.line),
              itemBuilder: (context, i) {
                final p = _predictions[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.location_on_outlined,
                      color: Color(0xFF7A7C86)),
                  title: Text(p.primary,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: p.secondary.isEmpty
                      ? null
                      : Text(p.secondary,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, p),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
