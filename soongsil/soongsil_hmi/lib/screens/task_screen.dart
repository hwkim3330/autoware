import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/autoware_state.dart';
import '../providers/monitor_provider.dart';
import 'widgets/map_view.dart';

// Tesla Model 3/Y v11 palette (matches the ROii Command dashboard).
const kBg = Color(0xFF171717);
const kPanel = Color(0xFF1B1B1B);
const kHi = Color(0xFFF4F4F4);
const kLo = Color(0xFF8E8E93);
const kBlue = Color(0xFF3E6AE1);
const kGreen = Color(0xFF2DB300);
const kAmber = Color(0xFFF59E0B);
const kRed = Color(0xFFD32F2F);

class TaskScreen extends ConsumerStatefulWidget {
  const TaskScreen({super.key});
  @override
  ConsumerState<TaskScreen> createState() => _S();
}

class _S extends ConsumerState<TaskScreen> {
  void _send(Map<String, dynamic> m) => ref.read(wsMonitorServiceProvider).send(m);

  bool _ok(AutowareState s, String id) {
    final r = s.roii;
    if (r != null && r['sensors'] is Map) {
      final st = (r['sensors'][id]?['status'] ?? r['sensors'][id])?.toString();
      if (st != null) return st.toUpperCase().contains('OK') || st.toUpperCase().contains('NORMAL');
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(autowareStateProvider);
    final s = async.valueOrNull ?? AutowareState.disconnected();
    final connected = async.hasValue && s.locMode != 'DISCONNECTED';
    final lanes = ref.watch(lanesProvider).valueOrNull ?? const <List<double>>[];
    final polys = ref.watch(lanePolysProvider).valueOrNull ?? const <List<List<double>>>[];

    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        Expanded(child: Row(children: [
          SizedBox(width: 326, child: _LeftPanel(s: s, connected: connected, ok: _ok)),
          Container(width: 1, color: Colors.black),
          Expanded(child: Stack(fit: StackFit.expand, children: [
            MapView(s: s, lanes: lanes, polys: polys, onTapWorld: (x, y) {
              if (connected) _send({'cmd': 'goto', 'x': x, 'y': y});
            }),
            Positioned(top: 12, left: 0, right: 0, child: Center(child: _Banner(s: s))),
            if (!connected)
              const IgnorePointer(child: Center(
                child: Text('게이트웨이 연결 대기...', style: TextStyle(color: kLo, fontSize: 15)))),
          ])),
        ])),
        _Dock(connected: connected, send: _send),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
class _LeftPanel extends StatelessWidget {
  final AutowareState s; final bool connected;
  final bool Function(AutowareState, String) ok;
  const _LeftPanel({required this.s, required this.connected, required this.ok});

  @override
  Widget build(BuildContext context) {
    final spd = s.speedKmh.abs();
    final gear = !connected ? 'P' : (s.speedKmh < -0.3 ? 'R' : (s.isAutonomous || s.isDriving ? 'D' : 'P'));
    return Container(
      color: kPanel,
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // PRND strip + connectivity (Tesla top bar)
        Row(children: [
          for (final g in const ['P', 'R', 'N', 'D'])
            Padding(padding: const EdgeInsets.only(right: 12),
              child: Text(g, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                  color: g == gear ? kHi : kLo.withValues(alpha: 0.45)))),
          const Spacer(),
          Icon(connected ? Icons.usb : Icons.usb_off, size: 16, color: connected ? kLo : kRed),
        ]),
        // big speed + AUTOPILOT (Tesla)
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(spd.toStringAsFixed(0), style: const TextStyle(color: kHi, fontSize: 64, fontWeight: FontWeight.w300, height: 1)),
          const SizedBox(width: 6),
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('km/h', style: TextStyle(color: kLo, fontSize: 14))),
          const Spacer(),
          if (s.isAutonomous)
            Padding(padding: const EdgeInsets.only(bottom: 14),
              child: Text('AUTOPILOT', style: TextStyle(color: kBlue, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2))),
        ]),
        const SizedBox(height: 6),
        // 4-LiDAR coverage diagram (Tesla render area)
        Center(child: _VehicleLidarView(
          okOf: (id) => ok(s, id),
          onFault: (id) {},  // tap handled inside via callbacks below
          onHeal: (id) {},
          send: (m) => null,
        )),
        const SizedBox(height: 4),
        const Text('LiDAR  ·  탭=고장주입 · 길게=복구', style: TextStyle(color: kLo, fontSize: 10.5)),
        const SizedBox(height: 10),
        _Trip('Localization', s.locMode, s.locMode == 'LIDAR_GNSS' ? kGreen : (s.locMode == 'GNSS_IMU' ? kAmber : kLo)),
        _Trip('NDT', '${s.ndtHz.toStringAsFixed(1)} Hz', s.localized ? kGreen : kRed),
        _Trip('Route', s.routeState, s.routeState == 'SET' ? kGreen : kLo),
        _Trip('Trajectory', s.trajPoints > 0 ? '${s.trajPoints} pts' : '—', s.trajPoints > 0 ? kGreen : kLo),
        const SizedBox(height: 10),
        const Text('MRM 최소위험기동', style: TextStyle(color: kLo, fontSize: 10.5, letterSpacing: 1)),
        const SizedBox(height: 5),
        _MrmLadder(mrm: s.mrm),
      ]),
    );
  }
}

class _Trip extends StatelessWidget {
  final String k, v; final Color c;
  const _Trip(this.k, this.v, this.c);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2.5),
    child: Row(children: [
      Text(k, style: const TextStyle(color: kLo, fontSize: 12)),
      const Spacer(),
      Text(v, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
    ]),
  );
}

// reuse the live state via an InheritedWidget-free approach: the diagram gets
// its fault/heal sender through a Riverpod lookup at tap time.
class _VehicleLidarView extends ConsumerStatefulWidget {
  final bool Function(String id) okOf;
  final void Function(String id) onFault, onHeal;
  final dynamic Function(Map<String, dynamic>) send;
  const _VehicleLidarView({required this.okOf, required this.onFault, required this.onHeal, required this.send});
  static const sectors = [
    ('front_g32', 'G32-F', -90.0, 70.0, Offset(0, -1)),
    ('rear_g32', 'G32-R', 90.0, 70.0, Offset(0, 1)),
    ('left_pandar', 'PND-L', 180.0, 120.0, Offset(-1, 0)),
    ('right_pandar', 'PND-R', 0.0, 120.0, Offset(1, 0)),
  ];
  @override
  ConsumerState<_VehicleLidarView> createState() => _VehicleLidarViewState();
}

class _VehicleLidarViewState extends ConsumerState<_VehicleLidarView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  void _send(Map<String, dynamic> m) => ref.read(wsMonitorServiceProvider).send(m);
  @override
  Widget build(BuildContext context) {
    const w = 286.0, h = 188.0;
    const ctr = Offset(w / 2, h / 2);
    return SizedBox(width: w, height: h, child: Stack(children: [
      AnimatedBuilder(animation: _c, builder: (_, __) =>
        CustomPaint(size: const Size(w, h), painter: _VehPainter(widget.okOf, _c.value))),
      for (final s in _VehicleLidarView.sectors)
        Positioned(
          left: ctr.dx + s.$5.dx * 104 - 30, top: ctr.dy + s.$5.dy * 74 - 16,
          child: GestureDetector(
            onTap: () => _send({'cmd': 'fault', 'sensor': s.$1, 'mode': 'drop'}),
            onLongPress: () => _send({'cmd': 'fault', 'sensor': s.$1, 'mode': 'normal'}),
            child: Container(width: 60, height: 32, alignment: Alignment.center, color: Colors.transparent,
              child: Text(s.$2, style: TextStyle(color: widget.okOf(s.$1) ? kGreen : kRed, fontSize: 11, fontWeight: FontWeight.w800))),
          ),
        ),
    ]));
  }
}

class _VehPainter extends CustomPainter {
  final bool Function(String id) okOf;
  final double t;
  _VehPainter(this.okOf, this.t);
  static const _sec = _VehicleLidarView.sectors;
  @override
  void paint(Canvas c, Size s) {
    final ctr = Offset(s.width / 2, s.height / 2);
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);   // gentle, faults only
    // faint static coverage + a clean LiDAR node dot per corner (Tesla-clean)
    for (final sec in _sec) {
      final ok = okOf(sec.$1);
      final col = ok ? kGreen : kRed;
      final start = (sec.$3 - sec.$4 / 2) * math.pi / 180;
      final sweep = sec.$4 * math.pi / 180;
      final r = sec.$4 > 100 ? 86.0 : 78.0;
      final rect = Rect.fromCircle(center: ctr, radius: r);
      final fillA = ok ? 0.10 : (0.10 + 0.22 * pulse);     // subtle; faults breathe
      c.drawArc(rect, start, sweep, true,
          Paint()..shader = RadialGradient(colors: [col.withValues(alpha: fillA), col.withValues(alpha: 0.0)]).createShader(rect));
      // node dot at the sensor position (on the car edge toward the sector)
      final node = ctr + sec.$5 * (sec.$5.dy != 0 ? 30 : 17);
      final glow = ok ? 0.9 : (0.5 + 0.5 * pulse);
      c.drawCircle(node, 7, Paint()..color = col.withValues(alpha: 0.18 * glow));
      c.drawCircle(node, 3.4, Paint()..color = col.withValues(alpha: glow));
    }
    // clean vehicle silhouette (top view, nose up)
    final body = RRect.fromRectAndRadius(Rect.fromCenter(center: ctr, width: 30, height: 58), const Radius.circular(11));
    c.drawRRect(body, Paint()..color = const Color(0xFF20242B));
    c.drawRRect(body, Paint()..color = Colors.white24..style = PaintingStyle.stroke..strokeWidth = 1.2);
    // windshield hint + nose
    c.drawLine(Offset(ctr.dx - 9, ctr.dy - 8), Offset(ctr.dx + 9, ctr.dy - 8),
        Paint()..color = Colors.white12..strokeWidth = 1);
    c.drawCircle(Offset(ctr.dx, ctr.dy - 21), 2.5, Paint()..color = kBlue);
  }
  @override
  bool shouldRepaint(covariant _VehPainter o) => o.t != t;
}

class _MrmLadder extends StatelessWidget {
  final String mrm;
  const _MrmLadder({required this.mrm});
  @override
  Widget build(BuildContext context) {
    final m = mrm.toUpperCase();
    final stage = m.isEmpty || m.contains('NORMAL') ? 0
        : m.contains('COMFORT') ? 1 : m.contains('EMERGENCY') ? 2 : m.contains('PULL') ? 3 : 2;
    const labels = ['NORMAL', 'COMFORTABLE STOP', 'EMERGENCY STOP', 'PULL OVER 갓길'];
    const cols = [kGreen, kAmber, kRed, kBlue];
    return Row(children: [
      for (int i = 0; i < 4; i++)
        Expanded(child: Container(
          margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: stage == i ? cols[i].withValues(alpha: 0.22) : kBg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: stage == i ? cols[i] : Colors.white10),
          ),
          child: Column(children: [
            Text('${i + 1}', style: TextStyle(color: stage == i ? cols[i] : kLo, fontWeight: FontWeight.w900, fontSize: 12)),
            const SizedBox(height: 2),
            Text(labels[i].split(' ').first, style: TextStyle(color: stage == i ? kHi : kLo, fontSize: 8, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          ]),
        )),
    ]);
  }
}

class _Banner extends StatelessWidget {
  final AutowareState s;
  const _Banner({required this.s});
  @override
  Widget build(BuildContext context) {
    if (s.mrm.isNotEmpty) {
      return _pill('⚠ MRM · ${s.mrm}', kRed, filled: true);
    }
    final auto = s.operationMode == 'AUTONOMOUS';
    return _pill(auto ? 'AUTONOMOUS' : s.operationMode, auto ? kGreen : kLo);
  }
  Widget _pill(String t, Color c, {bool filled = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
    decoration: BoxDecoration(
      color: filled ? c : c.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: filled ? c : c.withValues(alpha: 0.6))),
    child: Text(t, style: TextStyle(color: filled ? Colors.white : c, fontWeight: FontWeight.w800, fontSize: 13)),
  );
}

class _Dock extends StatelessWidget {
  final bool connected; final void Function(Map<String, dynamic>) send;
  const _Dock({required this.connected, required this.send});
  @override
  Widget build(BuildContext context) {
    return Container(height: 58, color: kPanel, padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(children: [
        _i(Icons.near_me, connected ? () => send({'cmd': 'drive'}) : null, kBlue),
        const SizedBox(width: 34),
        _i(Icons.stop_circle_outlined, connected ? () => send({'cmd': 'stop'}) : null, kRed),
        const SizedBox(width: 34),
        _i(Icons.sensors_off, connected ? () => send({'cmd': 'fault', 'sensor': 'all', 'mode': 'drop'}) : null, kAmber),
        const SizedBox(width: 34),
        _i(Icons.healing, connected ? () => send({'cmd': 'heal'}) : null, kGreen),
        const Spacer(),
        _i(Icons.restart_alt, connected ? () => send({'cmd': 'respawn'}) : null, kHi),
        const SizedBox(width: 22),
        _Emerg(onTap: connected ? () => send({'cmd': 'trigger_emergency'}) : null),
      ]),
    );
  }
  Widget _i(IconData ic, VoidCallback? onTap, Color c) => InkWell(
    onTap: onTap, customBorder: const CircleBorder(),
    child: Padding(padding: const EdgeInsets.all(7),
      child: Icon(ic, color: onTap == null ? kLo.withValues(alpha: 0.3) : c, size: 28)),
  );
}

class _Emerg extends StatelessWidget {
  final VoidCallback? onTap;
  const _Emerg({required this.onTap});
  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return Material(color: on ? kRed : kRed.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(20),
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(20),
        child: const Padding(padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            SizedBox(width: 5),
            Text('EMERGENCY', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
          ]))),
    );
  }
}
