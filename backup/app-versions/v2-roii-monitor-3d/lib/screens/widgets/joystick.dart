import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Virtual joystick. Vertical = velocity (up forward / down reverse),
/// horizontal = steering. Emits (v m/s, steer rad) ~15 Hz while dragged,
/// and a single zero on release.
class Joystick extends StatefulWidget {
  final double size;
  final double maxSpeed;   // m/s at full deflection
  final double maxSteer;   // rad at full deflection
  final void Function(double v, double steer) onChanged;
  const Joystick({
    super.key,
    this.size = 180,
    this.maxSpeed = 5.0,
    this.maxSteer = 0.5,
    required this.onChanged,
  });

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero; // -1..1 each axis
  Timer? _ticker;

  void _start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 66), (_) => _emit());
  }

  void _emit() {
    final v = -_knob.dy * widget.maxSpeed;       // up (negative dy) = forward
    final steer = -_knob.dx * widget.maxSteer;   // left = positive steer
    widget.onChanged(v, steer);
  }

  void _update(Offset local) {
    final r = widget.size / 2;
    var dx = (local.dx - r) / r;
    var dy = (local.dy - r) / r;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 1) { dx /= len; dy /= len; } // clamp to unit circle
    setState(() => _knob = Offset(dx, dy));
  }

  void _release() {
    _ticker?.cancel();
    setState(() => _knob = Offset.zero);
    widget.onChanged(0, 0); // stop
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.size / 2;
    return GestureDetector(
      onPanStart: (d) { _start(); _update(d.localPosition); },
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xCC0B1220),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16)],
        ),
        child: Stack(
          children: [
            // axis hints
            Center(child: Icon(Icons.keyboard_arrow_up, color: Colors.white24, size: 22)),
            Align(alignment: const Alignment(0, 0.85), child: Icon(Icons.keyboard_arrow_down, color: Colors.white24, size: 22)),
            // knob
            Align(
              alignment: Alignment(_knob.dx, _knob.dy),
              child: Container(
                width: r, height: r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(colors: [Color(0xFF22D3EE), Color(0xFF0E7490)]),
                  boxShadow: [BoxShadow(color: const Color(0xFF22D3EE).withValues(alpha: 0.5), blurRadius: 12)],
                ),
                child: const Icon(Icons.control_camera, color: Colors.white, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

