import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/autoware_state.dart';

/// Real-map view: renders the autonomous Niro on an actual OpenStreetMap
/// basemap (숭실대 / 판교 …). The ego pose + all paths arrive in a LOCAL map
/// frame (metres relative to the site geo-origin in [AutowareState.site]);
/// we convert them to WGS84 with the same equirectangular projection the map
/// was built with, draw the route/trajectory/lanelets as polylines, place an
/// oriented ego marker, follow the ego with the camera, and turn taps back
/// into local-metre destinations for the tap-to-go autonomy flow.
class OsmMapView extends StatefulWidget {
  final AutowareState s;
  final List<List<List<double>>> polys; // per-lanelet polylines (local metres)
  final void Function(double x, double y) onTapWorld;
  const OsmMapView(
      {super.key,
      required this.s,
      this.polys = const [],
      required this.onTapWorld});

  @override
  State<OsmMapView> createState() => _OsmMapViewState();
}

class _OsmMapViewState extends State<OsmMapView> {
  final MapController _controller = MapController();
  bool _ready = false;
  LatLng? _lastEgo;

  // geo-origin from the state frame; falls back to (0,0) if absent.
  double get _lat0 {
    final v = widget.s.site?['lat'];
    return (v is num) ? v.toDouble() : 0.0;
  }

  double get _lon0 {
    final v = widget.s.site?['lon'];
    return (v is num) ? v.toDouble() : 0.0;
  }

  /// local metres (x east, y north) -> WGS84.
  LatLng _toLatLng(double x, double y) {
    final lat0 = _lat0, lon0 = _lon0;
    final lat = lat0 + (y / 111320.0);
    final lon = lon0 + (x / (111320.0 * math.cos(lat0 * math.pi / 180.0)));
    return LatLng(lat, lon);
  }

  /// WGS84 -> local metres (inverse of [_toLatLng]).
  (double, double) _toWorld(LatLng p) {
    final lat0 = _lat0, lon0 = _lon0;
    final y = (p.latitude - lat0) * 111320.0;
    final x = (p.longitude - lon0) * 111320.0 * math.cos(lat0 * math.pi / 180.0);
    return (x, y);
  }

  List<LatLng> _path(List<List<double>> pts) {
    final out = <LatLng>[];
    for (final p in pts) {
      if (p.length >= 2) out.add(_toLatLng(p[0], p[1]));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ego = _toLatLng(widget.s.x, widget.s.y);

    // Follow the ego: recenter when it has moved meaningfully (after first
    // frame is laid out so the controller is attached).
    if (_ready && (_lastEgo == null || _moved(_lastEgo!, ego))) {
      _lastEgo = ego;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.move(ego, _controller.camera.zoom);
      });
    }

    final route = _path(widget.s.routePath);
    final traj = _path(widget.s.trajPath);

    final lanePolylines = <Polyline>[];
    for (final poly in widget.polys) {
      if (poly.length < 2) continue;
      lanePolylines.add(Polyline(
        points: _path(poly),
        color: const Color(0x66708090),
        strokeWidth: 1.5,
      ));
    }

    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: ego,
        initialZoom: 17,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () {
          _ready = true;
          _lastEgo = ego;
        },
        onTap: (tapPosition, latlng) {
          final (x, y) = _toWorld(latlng);
          widget.onTapWorld(x, y);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.keti.awsim_tesla',
          maxZoom: 19,
        ),
        if (lanePolylines.isNotEmpty)
          PolylineLayer(polylines: lanePolylines),
        if (route.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: route,
              color: const Color(0x553E6AE1),
              strokeWidth: 9,
            ),
          ]),
        if (traj.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: traj,
              color: const Color(0xFF4E86FF),
              strokeWidth: 5,
            ),
          ]),
        if (route.length > 1)
          MarkerLayer(markers: [
            Marker(
              point: route.last,
              width: 24,
              height: 24,
              child: const Icon(Icons.place, color: Color(0xFFD32F2F), size: 24),
            ),
          ]),
        MarkerLayer(markers: [
          Marker(
            point: ego,
            width: 44,
            height: 44,
            child: Transform.rotate(
              // Icons.navigation points up (north). World yaw is CCW from east
              // (+x). On the north-up map, screen-clockwise = -yaw, and east must
              // map to "right" so add +90deg: angle = pi/2 - yaw.
              angle: math.pi / 2 - widget.s.yawDeg * math.pi / 180.0,
              child: _EgoMarker(autop: widget.s.isAutonomous),
            ),
          ),
        ]),
      ],
    );
  }

  bool _moved(LatLng a, LatLng b) {
    final dlat = (a.latitude - b.latitude).abs();
    final dlon = (a.longitude - b.longitude).abs();
    return dlat > 1e-6 || dlon > 1e-6; // ~0.1 m
  }
}

class _EgoMarker extends StatelessWidget {
  final bool autop;
  const _EgoMarker({required this.autop});
  @override
  Widget build(BuildContext context) {
    final accent =
        autop ? const Color(0xFF3E6AE1) : const Color(0xFF2563EB);
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 12),
        ],
      ),
      child: Center(
        child: Icon(Icons.navigation, color: accent, size: 30),
      ),
    );
  }
}
