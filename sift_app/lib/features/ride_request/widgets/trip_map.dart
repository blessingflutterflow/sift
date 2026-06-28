import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/map_style.dart';
import '../../trip/route_tracker.dart';
import 'map_markers.dart';

/// The rider's live-tracking map: the driver's car **glides** between
/// telemetry updates and rotates to the road's direction, the (already
/// trimmed) route line shrinks ahead of it, and the camera keeps car + target
/// framed.
///
/// The parent feeds the snapped driver position, road-aligned [heading] and
/// remaining [route] from a RouteTracker; this widget only does presentation.
class TripMap extends StatefulWidget {
  const TripMap({
    super.key,
    required this.driver,
    required this.target,
    required this.route,
    this.heading,
    this.targetIsDestination = false,
    this.vehicleIsBike = false,
  });

  /// Live driver position (animated). Null until the driver shares location.
  final LatLng? driver;

  /// Pickup or destination the driver is heading to.
  final LatLng target;

  /// Remaining route polyline (driver → target). Empty falls back to a line.
  final List<LatLng> route;

  /// Road-aligned travel direction; falls back to movement bearing.
  final double? heading;

  /// Shows the destination flag instead of the pickup person marker.
  final bool targetIsDestination;

  /// Render the driver as a bike instead of a car (Sift Bike trips).
  final bool vehicleIsBike;

  @override
  State<TripMap> createState() => _TripMapState();
}

class _TripMapState extends State<TripMap> with SingleTickerProviderStateMixin {
  GoogleMapController? _map;

  late final AnimationController _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..addListener(_onTick);

  LatLng? _from; // animating from
  LatLng? _to; // animating to
  LatLng? _shown; // currently displayed
  double _bearing = 0;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    MapMarkers.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _shown = widget.driver;
    _to = widget.driver;
    if (widget.heading != null) _bearing = widget.heading!;
  }

  @override
  void didUpdateWidget(covariant TripMap old) {
    super.didUpdateWidget(old);
    final next = widget.driver;
    if (next != null && next != _to) {
      final now = DateTime.now();
      // Glide over (roughly) the real telemetry interval so the car moves
      // continuously instead of hop-pause-hop.
      final gap = now.difference(_lastUpdate).inMilliseconds.clamp(450, 4000);
      _lastUpdate = now;
      _from = _shown ?? next;
      _to = next;
      _bearing = widget.heading ?? _movementBearing(_from!, next);
      _glide
        ..duration = Duration(milliseconds: gap)
        ..reset()
        ..forward();
    }
  }

  double _movementBearing(LatLng a, LatLng b) {
    // Under ~3m of movement the bearing is noise — keep the previous one.
    if ((b.latitude - a.latitude).abs() < 0.00003 &&
        (b.longitude - a.longitude).abs() < 0.00003) {
      return _bearing;
    }
    return RouteTracker.bearingBetween(a, b);
  }

  void _onTick() {
    if (_from == null || _to == null) return;
    final t = Curves.easeInOut.transform(_glide.value);
    _shown = LatLng(
      _from!.latitude + (_to!.latitude - _from!.latitude) * t,
      _from!.longitude + (_to!.longitude - _from!.longitude) * t,
    );
    // Throttle camera framing to keep it smooth, not jittery.
    final now = DateTime.now();
    if (now.difference(_lastFrame).inMilliseconds > 2500) {
      _lastFrame = now;
      _frame();
    }
    setState(() {});
  }

  void _frame() {
    if (_map == null) return;
    final a = _shown;
    if (a == null) {
      _map!.animateCamera(CameraUpdate.newLatLngZoom(widget.target, 14));
      return;
    }
    _map!.animateCamera(
      CameraUpdate.newLatLngBounds(_bounds(a, widget.target), 90),
    );
  }

  LatLngBounds _bounds(LatLng a, LatLng b) => LatLngBounds(
        southwest: LatLng(math.min(a.latitude, b.latitude),
            math.min(a.longitude, b.longitude)),
        northeast: LatLng(math.max(a.latitude, b.latitude),
            math.max(a.longitude, b.longitude)),
      );

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('target'),
        position: widget.target,
        icon: (widget.targetIsDestination
                ? MapMarkers.flag
                : MapMarkers.person) ??
            BitmapDescriptor.defaultMarker,
        anchor: widget.targetIsDestination
            ? const Offset(0.5, 0.5)
            : const Offset(0.5, 0.9),
      ),
      if (_shown != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: _shown!,
          icon: (widget.vehicleIsBike ? MapMarkers.bike : MapMarkers.car) ??
              BitmapDescriptor.defaultMarker,
          rotation: _bearing,
          anchor: const Offset(0.5, 0.5),
          flat: true,
        ),
    };

    final line =
        widget.route.length >= 2 ? widget.route : [?_shown, widget.target];

    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: widget.driver ?? widget.target,
        zoom: 14,
      ),
      style: kDarkMapStyle,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: false,
      markers: markers,
      polylines: {
        if (line.length >= 2)
          Polyline(
            polylineId: const PolylineId('route'),
            points: line,
            color: AppColors.green,
            width: 4,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
      },
      onMapCreated: (c) {
        _map = c;
        _frame();
      },
    );
  }
}
