import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/localization_state.dart';
import '../models/sensor_state.dart';
import '../theme/app_theme.dart';

/// Tesla-autopilot-style top-down vehicle visualization (ROii layout).
/// Pure CustomPainter — no 3D / external packages. Renders the car body,
/// the ROii sensor suite (LiDAR / Camera / Radar) color-coded by live status,
/// LiDAR scan rings + camera FOV cones for the sensors currently used by the
/// active localization mode. Includes a slow animated LiDAR sweep.
class VehicleVisualizer extends StatefulWidget {
  final SensorSet sensors;
  final LocalizationState localization;
  const VehicleVisualizer({
    super.key,
    required this.sensors,
    required this.localization,
  });

  @override
  State<VehicleVisualizer> createState() => _VehicleVisualizerState();
}

class _VehicleVisualizerState extends State<VehicleVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 0.72,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _VehiclePainter(
            sensors: widget.sensors,
            loc: widget.localization,
            sweep: _c.value,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _Sensor {
  final String label;
  final double nx; // 0..1 across width
  final double ny; // 0..1 along length (0 = front)
  final String kind; // lidar | camera | radar
  final double heading; // degrees, 0 = forward(up), for FOV direction
  const _Sensor(this.label, this.nx, this.ny, this.kind, this.heading);
}

/// ROii sensor placement (normalized to the car body box).
const List<_Sensor> _layout = [
  // LiDAR
  _Sensor('LiDAR-FC', 0.50, 0.06, 'lidar', 0),
  _Sensor('LiDAR-FL', 0.18, 0.16, 'lidar', -35),
  _Sensor('LiDAR-FR', 0.82, 0.16, 'lidar', 35),
  _Sensor('LiDAR-RC', 0.50, 0.95, 'lidar', 180),
  // Cameras
  _Sensor('Cam-FC', 0.50, 0.20, 'camera', 0),
  _Sensor('Cam-FL', 0.30, 0.14, 'camera', -20),
  _Sensor('Cam-FR', 0.70, 0.14, 'camera', 20),
  _Sensor('Cam-SL1', 0.10, 0.38, 'camera', -90),
  _Sensor('Cam-SL2', 0.10, 0.62, 'camera', -90),
  _Sensor('Cam-SR1', 0.90, 0.38, 'camera', 90),
  _Sensor('Cam-SR2', 0.90, 0.62, 'camera', 90),
  _Sensor('Cam-RC', 0.50, 0.90, 'camera', 180),
  // Radar
  _Sensor('Radar-FL', 0.22, 0.04, 'radar', -25),
  _Sensor('Radar-FC', 0.50, 0.02, 'radar', 0),
  _Sensor('Radar-FR', 0.78, 0.04, 'radar', 25),
  _Sensor('Radar-RL', 0.24, 0.98, 'radar', 205),
  _Sensor('Radar-RR', 0.76, 0.98, 'radar', 155),
];

class _VehiclePainter extends CustomPainter {
  final SensorSet sensors;
  final LocalizationState loc;
  final double sweep;
  _VehiclePainter({required this.sensors, required this.loc, required this.sweep});

  SensorStatus _statusFor(String kind) {
    final s = sensors.sensors[kind];
    return s?.status ?? SensorStatus.unknown;
  }

  bool _usedFor(String kind) {
    final s = sensors.sensors[kind];
    return s?.used ?? false;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Car body box centered, leaving margin for cones/rings.
    final bw = w * 0.42;
    final bh = h * 0.74;
    final left = (w - bw) / 2;
    final top = (h - bh) / 2;
    final body = Rect.fromLTWH(left, top, bw, bh);
    final cx = w / 2;

    // ground glow
    final bg = Paint()
      ..shader = RadialGradient(
        colors: [AppTheme.accent.withValues(alpha: 0.06), Colors.transparent],
      ).createShader(Rect.fromCircle(center: Offset(cx, h / 2), radius: w * 0.55));
    canvas.drawRect(Offset.zero & size, bg);

    final lidarUsed = _usedFor('lidar');
    final lidarColor = StatusColors.sensor(_statusFor('lidar'));

    // LiDAR concentric scan rings (only if lidar present/used)
    if (lidarUsed && _statusFor('lidar') == SensorStatus.normal) {
      for (int i = 1; i <= 3; i++) {
        final r = (w * 0.18) * i + sweep * (w * 0.06);
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = lidarColor.withValues(alpha: 0.22 - i * 0.05);
        canvas.drawCircle(Offset(cx, h * 0.42), r, ring);
      }
      // rotating sweep wedge
      final sweepAngle = sweep * 2 * math.pi;
      final wedge = Paint()
        ..shader = SweepGradient(
          startAngle: sweepAngle,
          endAngle: sweepAngle + 0.7,
          colors: [lidarColor.withValues(alpha: 0.30), Colors.transparent],
        ).createShader(Rect.fromCircle(center: Offset(cx, h * 0.42), radius: w * 0.5));
      canvas.drawCircle(Offset(cx, h * 0.42), w * 0.5, wedge);
    }

    // Camera FOV cones for used cameras
    if (_usedFor('camera')) {
      final camColor = StatusColors.sensor(_statusFor('camera'));
      for (final s in _layout.where((e) => e.kind == 'camera')) {
        _drawCone(canvas, body, s, camColor.withValues(alpha: 0.10), 70, h * 0.16);
      }
    }

    // ---- Car body ----
    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [const Color(0xFF2A3340), const Color(0xFF1A2028)],
      ).createShader(body);
    final rr = RRect.fromRectAndCorners(body,
        topLeft: Radius.circular(bw * 0.42),
        topRight: Radius.circular(bw * 0.42),
        bottomLeft: Radius.circular(bw * 0.28),
        bottomRight: Radius.circular(bw * 0.28));
    canvas.drawShadow(Path()..addRRect(rr), Colors.black, 8, true);
    canvas.drawRRect(rr, bodyPaint);
    canvas.drawRRect(rr,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = AppTheme.border);

    // windshield + rear glass (trapezoids)
    final glass = Paint()..color = AppTheme.accent.withValues(alpha: 0.12);
    final wsTop = top + bh * 0.20, wsBot = top + bh * 0.34;
    canvas.drawPath(
      Path()
        ..moveTo(left + bw * 0.16, wsBot)
        ..lineTo(left + bw * 0.84, wsBot)
        ..lineTo(left + bw * 0.72, wsTop)
        ..lineTo(left + bw * 0.28, wsTop)
        ..close(),
      glass,
    );
    final rgTop = top + bh * 0.70, rgBot = top + bh * 0.82;
    canvas.drawPath(
      Path()
        ..moveTo(left + bw * 0.20, rgTop)
        ..lineTo(left + bw * 0.80, rgTop)
        ..lineTo(left + bw * 0.74, rgBot)
        ..lineTo(left + bw * 0.26, rgBot)
        ..close(),
      glass,
    );
    // roof line
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(left + bw * 0.22, top + bh * 0.36, bw * 0.56, bh * 0.30),
          Radius.circular(bw * 0.1)),
      Paint()..color = Colors.white.withValues(alpha: 0.03),
    );

    // ---- Sensors ----
    for (final s in _layout) {
      final pos = Offset(left + s.nx * bw, top + s.ny * bh);
      final color = _sensorColor(s.kind);
      final used = (s.kind == 'lidar' && lidarUsed) ||
          (s.kind == 'camera' && _usedFor('camera'));
      _drawSensor(canvas, pos, color, used);
    }
  }

  Color _sensorColor(String kind) {
    switch (kind) {
      case 'lidar':
        return StatusColors.sensor(_statusFor('lidar'));
      case 'camera':
        return StatusColors.sensor(_statusFor('camera'));
      case 'radar':
        return StatusColors.amber;
      default:
        return AppTheme.textMuted;
    }
  }

  void _drawSensor(Canvas canvas, Offset p, Color color, bool used) {
    if (used) {
      canvas.drawCircle(p, 9,
          Paint()..color = color.withValues(alpha: 0.25)..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, 5));
    }
    canvas.drawCircle(p, 4.2, Paint()..color = color);
    canvas.drawCircle(p, 4.2,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = Colors.black.withValues(alpha: 0.4));
  }

  void _drawCone(Canvas canvas, Rect body, _Sensor s, Color color,
      double spreadDeg, double length) {
    final origin = Offset(body.left + s.nx * body.width, body.top + s.ny * body.height);
    final dir = (s.heading - 90) * math.pi / 180; // 0deg heading = up
    final half = spreadDeg / 2 * math.pi / 180;
    final p1 = origin + Offset(math.cos(dir - half), math.sin(dir - half)) * length;
    final p2 = origin + Offset(math.cos(dir + half), math.sin(dir + half)) * length;
    canvas.drawPath(
      Path()..moveTo(origin.dx, origin.dy)..lineTo(p1.dx, p1.dy)..lineTo(p2.dx, p2.dy)..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _VehiclePainter old) =>
      old.sweep != sweep || old.sensors != sensors || old.loc != loc;
}
