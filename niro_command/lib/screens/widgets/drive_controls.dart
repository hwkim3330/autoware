import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Gamepad-style driving controls spanning the bottom of the screen:
///  - LEFT: steering — joystick OR tilt mode (hold the tablet like a wheel;
///    zero point is calibrated the moment tilt mode is switched on).
///  - RIGHT: ACCEL (hold = forward) / REVERSE (hold = back) pedals.
/// Emits (v m/s, steer rad) ~20 Hz while active; a single zero on full release.
class DriveControls extends StatefulWidget {
  final double maxSpeed; // m/s at full accel
  final double maxSteer; // rad at full steer
  const DriveControls({
    super.key,
    this.maxSpeed = 6.0,
    this.maxSteer = 0.5,
    required this.onChanged,
  });
  final void Function(double v, double steer) onChanged;

  @override
  State<DriveControls> createState() => _DriveControlsState();
}

class _DriveControlsState extends State<DriveControls> {
  Timer? _ticker;
  double _throttle = 0; // -1 reverse .. +1 accel
  double _steerX = 0;   // -1..1 (joystick x or tilt)
  bool _accelDown = false, _revDown = false;
  bool _sentNonZero = false;

  // --- tilt steering ---
  bool _tilt = false;
  StreamSubscription<AccelerometerEvent>? _accSub;
  double? _rollZero;             // calibrated zero (rad)
  static const _fullTilt = 0.45; // rad of device roll = full steer (~26°)

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final active = _accelDown || _revDown || _steerX.abs() > 0.02;
      if (!active) {
        if (_sentNonZero) { widget.onChanged(0, 0); _sentNonZero = false; }
        return;
      }
      _sentNonZero = true;
      widget.onChanged(_throttle * widget.maxSpeed, -_steerX * widget.maxSteer);
    });
  }

  void _setTilt(bool on) {
    setState(() { _tilt = on; _steerX = 0; _rollZero = null; });
    _accSub?.cancel(); _accSub = null;
    if (on) {
      _accSub = accelerometerEventStream().listen((e) {
        // device roll from gravity in the screen plane; works in any landscape
        // because the zero point is captured when tilt mode is enabled.
        final roll = math.atan2(e.y, e.x);
        _rollZero ??= roll;
        var d = roll - _rollZero!;
        while (d > math.pi) { d -= 2 * math.pi; }
        while (d < -math.pi) { d += 2 * math.pi; }
        final x = (d / _fullTilt).clamp(-1.0, 1.0);
        if (mounted) setState(() => _steerX = x);
      });
    }
  }

  @override
  void dispose() { _ticker?.cancel(); _accSub?.cancel(); super.dispose(); }

  void _setThrottle() =>
      _throttle = _accelDown ? 1.0 : (_revDown ? -1.0 : 0.0);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(mainAxisSize: MainAxisSize.min, children: [
            _tilt
                ? _TiltGauge(x: _steerX)
                : _SteerStick(onChanged: (x) => setState(() => _steerX = x)),
            const SizedBox(height: 8),
            _tiltToggle(),
          ]),
          const Spacer(),
          _pedal('REVERSE', const Color(0xFFF59E0B), Icons.arrow_downward, _revDown,
              (d) => setState(() { _revDown = d; _setThrottle(); })),
          const SizedBox(width: 16),
          _pedal('ACCEL', const Color(0xFF16A34A), Icons.arrow_upward, _accelDown,
              (d) => setState(() { _accelDown = d; _setThrottle(); })),
        ],
      ),
    );
  }

  Widget _tiltToggle() => Material(
        color: _tilt ? const Color(0xFF3E6AE1) : const Color(0xCC1B2433),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _setTilt(!_tilt),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_tilt ? Icons.screen_rotation : Icons.gamepad,
                  color: Colors.white, size: 15),
              const SizedBox(width: 6),
              Text(_tilt ? 'TILT ON' : 'TILT',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );

  Widget _pedal(String label, Color c, IconData icon, bool down, void Function(bool) onHold) {
    return Listener(
      onPointerDown: (_) => onHold(true),
      onPointerUp: (_) => onHold(false),
      onPointerCancel: (_) => onHold(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        width: 110, height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            c.withValues(alpha: down ? 1.0 : 0.7), c.withValues(alpha: down ? 0.7 : 0.35),
          ]),
          border: Border.all(color: Colors.white.withValues(alpha: down ? 0.9 : 0.3), width: 3),
          boxShadow: [BoxShadow(color: c.withValues(alpha: down ? 0.7 : 0.25), blurRadius: down ? 22 : 10)],
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 30),
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        ]),
      ),
    );
  }
}

/// Tilt-steering gauge: a steering wheel that rotates with the device roll and
/// a horizontal bar showing the commanded steer.
class _TiltGauge extends StatelessWidget {
  final double x; // -1..1
  const _TiltGauge({required this.x});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150, height: 150,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xCC0B1220),
        border: Border.all(color: const Color(0xFF3E6AE1).withValues(alpha: 0.5), width: 2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16)],
      ),
      child: Stack(alignment: Alignment.center, children: [
        const Positioned(top: 14, child: Text('TILT STEER',
            style: TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1.2))),
        Transform.rotate(
          angle: x * 1.2,
          child: const Icon(Icons.radio_button_unchecked, color: Color(0xFF3E6AE1), size: 84),
        ),
        Transform.rotate(
          angle: x * 1.2,
          child: Container(width: 70, height: 4,
              decoration: BoxDecoration(color: const Color(0xFF3E6AE1),
                  borderRadius: BorderRadius.circular(2))),
        ),
        Positioned(
          bottom: 18,
          child: SizedBox(width: 100, height: 6,
            child: Stack(children: [
              Container(decoration: BoxDecoration(
                  color: Colors.white12, borderRadius: BorderRadius.circular(3))),
              Align(
                alignment: Alignment(x, 0),
                child: Container(width: 14, height: 6,
                    decoration: BoxDecoration(color: Colors.white,
                        borderRadius: BorderRadius.circular(3))),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Horizontal steering joystick (knob slides left/right).
class _SteerStick extends StatefulWidget {
  final void Function(double x) onChanged;
  const _SteerStick({required this.onChanged});
  @override
  State<_SteerStick> createState() => _SteerStickState();
}

class _SteerStickState extends State<_SteerStick> {
  double _x = 0;
  static const double _size = 150;

  void _update(Offset local) {
    final r = _size / 2;
    var dx = ((local.dx - r) / r).clamp(-1.0, 1.0);
    setState(() => _x = dx);
    widget.onChanged(dx);
  }

  void _release() { setState(() => _x = 0); widget.onChanged(0); }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: Container(
        width: _size, height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xCC0B1220),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16)],
        ),
        child: Stack(alignment: Alignment.center, children: [
          const Align(alignment: Alignment(-0.7, 0), child: Icon(Icons.chevron_left, color: Colors.white24)),
          const Align(alignment: Alignment(0.7, 0), child: Icon(Icons.chevron_right, color: Colors.white24)),
          const Positioned(top: 16, child: Text('STEER', style: TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1.2))),
          Align(
            alignment: Alignment(_x, 0),
            child: Transform.rotate(
              angle: _x * 0.6,
              child: Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(colors: [Color(0xFF22D3EE), Color(0xFF0E7490)]),
                  boxShadow: [BoxShadow(color: const Color(0xFF22D3EE).withValues(alpha: 0.5), blurRadius: 12)],
                ),
                child: const Icon(Icons.fiber_manual_record, color: Colors.white70, size: 16),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
