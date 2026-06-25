import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/map_style.dart';
import '../ride_request/widgets/map_markers.dart';
import 'route_tracker.dart';

/// The driver's navigation map — a heading-up "windshield" view.
///
/// The camera follows the car (tilted, rotated to the direction of travel,
/// zoomed for streets) so the road ahead is always on screen. The driver shows
/// as a car marker gliding between GPS fixes; the target is the rider (person
/// marker) or the destination (flag). Panning breaks the follow and surfaces a
/// re-centre pill; [navigating] false (waiting at pickup) relaxes the camera
/// to a flat overview of car + rider.
class DriverNavMap extends StatefulWidget {
  const DriverNavMap({
    super.key,
    required this.self,
    required this.target,
    required this.route,
    this.heading,
    this.targetIsDestination = false,
    this.navigating = true,
    this.bottomPadding = 230,
  });

  /// Latest raw GPS fix for this device. Null until the first fix lands.
  final LatLng? self;

  /// Pickup (person) or destination (flag), per [targetIsDestination].
  final LatLng target;

  /// Remaining route polyline (already trimmed by RouteTracker).
  final List<LatLng> route;

  /// Road-aligned travel heading in degrees. Falls back to bearing computed
  /// from consecutive fixes.
  final double? heading;

  final bool targetIsDestination;
  final bool navigating;

  /// Keeps the camera target and Google logo clear of the bottom panel.
  final double bottomPadding;

  @override
  State<DriverNavMap> createState() => _DriverNavMapState();
}

class _DriverNavMapState extends State<DriverNavMap>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _map;

  late final AnimationController _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..addListener(() {
      if (mounted) setState(() {});
    });

  LatLng? _from;
  LatLng? _to;
  double _heading = 0;
  DateTime _lastFix = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCam = DateTime.fromMillisecondsSinceEpoch(0);

  bool _follow = true;
  // Set right before programmatic camera moves so onCameraMoveStarted can
  // tell our animations apart from the driver panning the map.
  bool _expectProgrammatic = false;

  LatLng? get _shown {
    final to = _to;
    if (to == null) return null;
    final from = _from ?? to;
    final t = Curves.easeInOut.transform(_glide.value);
    return LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
  }

  @override
  void initState() {
    super.initState();
    MapMarkers.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _to = widget.self;
    if (widget.heading != null) _heading = widget.heading!;
  }

  @override
  void didUpdateWidget(covariant DriverNavMap old) {
    super.didUpdateWidget(old);
    final next = widget.self;
    if (next != null && next != _to) {
      final now = DateTime.now();
      // Glide over (roughly) the real update interval so motion is continuous
      // instead of hop-pause-hop.
      final gap = now.difference(_lastFix).inMilliseconds.clamp(350, 2500);
      _lastFix = now;
      _from = _shown ?? next;
      _to = next;
      _heading = widget.heading ?? _bearingOrKeep(_from!, next);
      _glide
        ..duration = Duration(milliseconds: gap)
        ..reset()
        ..forward();
      _updateCamera(next);
    } else if (old.navigating != widget.navigating && _to != null) {
      _updateCamera(_to!);
    }
  }

  double _bearingOrKeep(LatLng a, LatLng b) {
    // Below ~3m of movement the bearing is GPS noise — keep the last one.
    if ((b.latitude - a.latitude).abs() < 0.00003 &&
        (b.longitude - a.longitude).abs() < 0.00003) {
      return _heading;
    }
    return RouteTracker.bearingBetween(a, b);
  }

  void _updateCamera(LatLng pos) {
    final map = _map;
    if (map == null || !_follow) return;
    final now = DateTime.now();
    if (now.difference(_lastCam).inMilliseconds < 800) return;
    _lastCam = now;
    _expectProgrammatic = true;
    map.animateCamera(
      CameraUpdate.newCameraPosition(
        widget.navigating
            ? CameraPosition(
                target: pos, zoom: 17, tilt: 48, bearing: _heading)
            : CameraPosition(target: pos, zoom: 16, tilt: 0, bearing: 0),
      ),
    );
  }

  void _recenter() {
    setState(() => _follow = true);
    _lastCam = DateTime.fromMillisecondsSinceEpoch(0);
    final pos = _shown ?? widget.self;
    if (pos != null) _updateCamera(pos);
  }

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;

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
      if (shown != null)
        Marker(
          markerId: const MarkerId('me'),
          position: shown,
          icon: MapMarkers.car ?? BitmapDescriptor.defaultMarker,
          rotation: _heading,
          anchor: const Offset(0.5, 0.5),
          flat: true,
        ),
    };

    final line = widget.route.length >= 2
        ? widget.route
        : [?shown, widget.target];

    return Stack(
      children: [
        Positioned.fill(
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: widget.self ?? widget.target,
              zoom: 16,
            ),
            style: kDarkMapStyle,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            buildingsEnabled: false,
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            markers: markers,
            polylines: {
              if (line.length >= 2)
                Polyline(
                  polylineId: const PolylineId('route'),
                  points: line,
                  color: AppColors.green,
                  width: 6,
                  startCap: Cap.roundCap,
                  endCap: Cap.roundCap,
                ),
            },
            onMapCreated: (c) {
              _map = c;
              final pos = _shown ?? widget.self;
              if (pos != null) {
                _lastCam = DateTime.fromMillisecondsSinceEpoch(0);
                _updateCamera(pos);
              }
            },
            onCameraMoveStarted: () {
              if (_expectProgrammatic) {
                _expectProgrammatic = false;
              } else if (_follow) {
                // The driver grabbed the map — stop chasing them.
                setState(() => _follow = false);
              }
            },
          ),
        ),
        if (!_follow)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 14,
            right: 16,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              elevation: 4,
              shadowColor: Colors.black26,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: _recenter,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.navigation, size: 18, color: AppColors.green),
                      SizedBox(width: 6),
                      Text('Re-centre',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.dark)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
