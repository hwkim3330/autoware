import 'package:flutter/material.dart';
import '../../models/autoware_state.dart';

/// Automotive-style glass panels overlaying the 3D model, driven by live
/// Autoware state. Dark, Tesla/ROii-dashboard aesthetic.
class StatusOverlay extends StatelessWidget {
  final AutowareState s;
  final bool connected;
  const StatusOverlay({super.key, required this.s, required this.connected});

  static const _accent = Color(0xFF22D3EE);   // cyan
  static const _ok = Color(0xFF34D399);       // green
  static const _warn = Color(0xFFF59E0B);     // amber
  static const _bad = Color(0xFFEF4444);      // red

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _leftColumn(),
                const Spacer(),
                _rightColumn(),
              ],
            ),
          ),
          _sensorRow(),
        ],
      ),
    );
  }

  Widget _glass({required Widget child, EdgeInsets? pad}) => Container(
        padding: pad ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xCC0B1220),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16)],
        ),
        child: child,
      );

  Widget _topBar() {
    return _glass(
      child: Row(
        children: [
          _dot(connected ? _ok : _bad),
          const SizedBox(width: 10),
          const Text('ROii Autoware Monitor',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(width: 16),
          _chip('CARLA · Town01', _accent),
          const Spacer(),
          _chip(connected ? 'LIVE' : 'DISCONNECTED', connected ? _ok : _bad),
        ],
      ),
    );
  }

  Widget _leftColumn() {
    final auto = s.isAutonomous;
    final modeColor = !connected
        ? _bad
        : auto
            ? _ok
            : (s.autonomousAvailable ? _accent : _warn);
    return _glass(
      pad: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _label('OPERATION MODE'),
          const SizedBox(height: 4),
          Text(connected ? s.operationMode : 'OFFLINE',
              style: TextStyle(color: modeColor, fontSize: 30, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          _label('SPEED'),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(s.speedKmh.toStringAsFixed(1),
                style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w200, height: 1)),
            const SizedBox(width: 6),
            const Text('km/h', style: TextStyle(color: Colors.white70, fontSize: 16)),
          ]),
          const SizedBox(height: 12),
          _kv('Localization', s.localized ? '${s.locMode}  ✓' : 'NOT CONVERGED',
              s.localized ? _ok : _warn),
          _kv('NDT rate', '${s.ndtHz.toStringAsFixed(1)} Hz', _accent),
          _kv('Route', s.routeState, s.routeState == 'SET' ? _ok : Colors.white70),
        ],
      ),
    );
  }

  Widget _rightColumn() {
    return _glass(
      pad: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _label('EGO POSE (map)'),
          const SizedBox(height: 6),
          _kv('x', s.x.toStringAsFixed(1), Colors.white),
          _kv('y', s.y.toStringAsFixed(1), Colors.white),
          _kv('yaw', '${s.yawDeg.toStringAsFixed(0)}°', Colors.white),
          const SizedBox(height: 10),
          _kv('Autonomous', s.autonomousAvailable ? 'AVAILABLE' : 'NOT READY',
              s.autonomousAvailable ? _ok : _warn),
        ],
      ),
    );
  }

  Widget _sensorRow() {
    Widget chip(String name, String status) {
      Color c = status == 'OK' ? _ok : (status == 'OFF' ? Colors.white38 : _bad);
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: _glass(
          pad: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _dot(c), const SizedBox(width: 8),
            Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(status, style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12)),
          ]),
        ),
      );
    }

    final sensors = s.sensors.isEmpty
        ? {'lidar': '-', 'gnss': '-', 'imu': '-', 'camera': '-'}
        : s.sensors;
    return Row(children: [
      for (final e in sensors.entries) chip(e.key.toUpperCase(), e.value),
    ]);
  }

  Widget _label(String t) =>
      Text(t, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w600));

  Widget _kv(String k, String v, Color vc) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 96, child: Text(k, style: const TextStyle(color: Colors.white60, fontSize: 13))),
          Text(v, style: TextStyle(color: vc, fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withValues(alpha: 0.5))),
        child: Text(t, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
      );

  Widget _dot(Color c) => Container(width: 10, height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 8)]));
}
