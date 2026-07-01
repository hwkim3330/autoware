import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/autoware_state.dart';
import '../providers/monitor_provider.dart';
import 'widgets/map_view.dart';
import 'widgets/drive_controls.dart';
import 'architecture_screen.dart';

/// ROii Command — premium unified autonomy cockpit (beyond a Tesla clone).
/// Hero nav map + glassy speed ring + autopilot status + a right rail that
/// surfaces what Tesla doesn't: full route, LiDAR-suite health, localization
/// mode (multimode), and live Autoware planning/control telemetry.
class CommandScreen extends ConsumerStatefulWidget {
  const CommandScreen({super.key});
  @override
  ConsumerState<CommandScreen> createState() => _S();
}

// premium palette
const cBg = Color(0xFF0B0E14);
const cGlass = Color(0xCC141925);
const cHi = Color(0xFFEAF0FF);
const cLo = Color(0xFF8A93A6);
const cAccent = Color(0xFF4E86FF);
const cGood = Color(0xFF30E0A1);
const cWarn = Color(0xFFFFC24B);
const cBad = Color(0xFFFF5470);

class _S extends ConsumerState<CommandScreen> {
  bool _manual = false;
  Offset? _dest;
  int _panel = 0; // 0 none, 1 sensors, 2 telemetry

  void _send(Map<String, dynamic> m) => ref.read(wsMonitorServiceProvider).send(m);

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(autowareStateProvider).valueOrNull ??
        AutowareState.disconnected();
    final connected = ref.watch(autowareStateProvider).hasValue &&
        s.locMode != 'DISCONNECTED';
    final lanes = ref.watch(lanesProvider).valueOrNull ?? const <List<double>>[];
    final polys =
        ref.watch(lanePolysProvider).valueOrNull ?? const <List<List<double>>>[];

    return Scaffold(
      backgroundColor: cBg,
      body: Stack(fit: StackFit.expand, children: [
        // ===== hero map =====
        MapView(
          s: s, lanes: lanes, polys: polys,
          onTapWorld: (x, y) {
            if (connected) setState(() => _dest = Offset(x, y));
          },
        ),

        // top gradient for legibility
        IgnorePointer(
          child: Container(
            height: 120,
            decoration: const BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Color(0xCC000000), Color(0x00000000)])),
          ),
        ),

        // ===== top status bar =====
        SafeArea(child: _TopBar(s: s, connected: connected)),

        // ===== left: speed ring HUD =====
        Positioned(
          left: 22, bottom: 26,
          child: SafeArea(top: false, child: _SpeedRing(s: s, connected: connected)),
        ),

        // ===== destination confirm chip =====
        if (_dest != null)
          Positioned(
            left: 0, right: 0, bottom: 30,
            child: Center(child: _ConfirmChip(
              dest: _dest!,
              onGo: () { _send({'cmd': 'goto', 'x': _dest!.dx, 'y': _dest!.dy}); setState(() => _dest = null); },
              onCancel: () => setState(() => _dest = null),
            )),
          ),

        // ===== right rail =====
        Positioned(
          right: 0, top: 0, bottom: 0,
          child: SafeArea(child: Row(children: [
            if (_panel != 0) _SidePanel(s: s, panel: _panel, send: _send),
            _Rail(
              connected: connected, manual: _manual, panel: _panel,
              onDrive: () => _send({'cmd': 'drive'}),
              onStop: () => _send({'cmd': 'stop'}),
              onManual: () => setState(() => _manual = !_manual),
              onSensors: () => setState(() => _panel = _panel == 1 ? 0 : 1),
              onTelemetry: () => setState(() => _panel = _panel == 2 ? 0 : 2),
              onArch: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ArchitectureScreen())),
            ),
          ])),
        ),

        // ===== manual controls =====
        if (_manual)
          Positioned(
            left: 0, right: 90, bottom: 16,
            child: DriveControls(
              onChanged: (v, st) => _send({'cmd': 'teleop', 'v': v, 'steer': st}),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
class _TopBar extends StatelessWidget {
  final AutowareState s; final bool connected;
  const _TopBar({required this.s, required this.connected});
  @override
  Widget build(BuildContext context) {
    final mode = s.isAutonomous ? 'AUTOPILOT' : (connected ? s.operationMode : 'OFFLINE');
    final mc = s.isAutonomous ? cAccent : (connected ? cWarn : cBad);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(children: [
        const Text('ROii', style: TextStyle(color: cHi, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2)),
        const Text(' COMMAND', style: TextStyle(color: cAccent, fontSize: 20, fontWeight: FontWeight.w300, letterSpacing: 2)),
        const SizedBox(width: 18),
        _pill(mode, mc),
        const Spacer(),
        if (s.mrm.isNotEmpty) _pill('⚠ ${s.mrm}', cBad),
        _chip('${s.locMode}', s.locMode == 'GNSS_IMU' ? cWarn : cGood),
        _chip('NDT ${s.ndtHz.toStringAsFixed(0)}Hz', connected ? cGood : cBad),
      ]),
    );
  }
  Widget _pill(String t, Color c) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20), border: Border.all(color: c.withValues(alpha: 0.6))),
        child: Text(t, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1)),
      );
  Widget _chip(String t, Color c) => Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: cGlass, borderRadius: BorderRadius.circular(20)),
        child: Text(t, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 11)),
      );
}

class _SpeedRing extends StatelessWidget {
  final AutowareState s; final bool connected;
  const _SpeedRing({required this.s, required this.connected});
  @override
  Widget build(BuildContext context) {
    final spd = s.speedKmh.abs();
    return SizedBox(
      width: 150, height: 150,
      child: Stack(alignment: Alignment.center, children: [
        CustomPaint(size: const Size(150, 150), painter: _RingPainter(
            value: (spd / 60).clamp(0.0, 1.0),
            color: s.isAutonomous ? cAccent : cGood)),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text(spd.toStringAsFixed(0), style: const TextStyle(
              color: cHi, fontSize: 48, fontWeight: FontWeight.w300, height: 1)),
          const Text('km/h', style: TextStyle(color: cLo, fontSize: 12)),
          if (s.plannedKmh > 0.5)
            Text('→ ${s.plannedKmh.toStringAsFixed(0)}', style: const TextStyle(color: cAccent, fontSize: 11)),
        ]),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value; final Color color;
  _RingPainter({required this.value, required this.color});
  @override
  void paint(Canvas c, Size s) {
    final ctr = Offset(s.width / 2, s.height / 2);
    final r = s.width / 2 - 8;
    const start = math.pi * 0.75, sweep = math.pi * 1.5;
    c.drawArc(Rect.fromCircle(center: ctr, radius: r), start, sweep, false,
        Paint()..color = cGlass..style = PaintingStyle.stroke..strokeWidth = 7..strokeCap = StrokeCap.round);
    c.drawArc(Rect.fromCircle(center: ctr, radius: r), start, sweep * value, false,
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 7..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawArc(Rect.fromCircle(center: ctr, radius: r), start, sweep * value, false,
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 7..strokeCap = StrokeCap.round);
  }
  @override
  bool shouldRepaint(covariant _RingPainter o) => o.value != value || o.color != color;
}

class _ConfirmChip extends StatelessWidget {
  final Offset dest; final VoidCallback onGo, onCancel;
  const _ConfirmChip({required this.dest, required this.onGo, required this.onCancel});
  @override
  Widget build(BuildContext context) => Material(
        color: cGlass, borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.place, color: cBad, size: 20),
            const SizedBox(width: 8),
            Text('(${dest.dx.toStringAsFixed(0)}, ${dest.dy.toStringAsFixed(0)})',
                style: const TextStyle(color: cLo, fontSize: 12)),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cAccent),
              onPressed: onGo,
              child: const Text('여기로 주행', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            IconButton(onPressed: onCancel, icon: const Icon(Icons.close, color: cLo, size: 18)),
          ]),
        ),
      );
}

class _Rail extends StatelessWidget {
  final bool connected, manual; final int panel;
  final VoidCallback onDrive, onStop, onManual, onSensors, onTelemetry, onArch;
  const _Rail({required this.connected, required this.manual, required this.panel,
      required this.onDrive, required this.onStop, required this.onManual,
      required this.onSensors, required this.onTelemetry, required this.onArch});
  @override
  Widget build(BuildContext context) => Container(
        width: 72,
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: cGlass, borderRadius: BorderRadius.circular(22)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          _b(Icons.near_me, 'DRIVE', cAccent, connected ? onDrive : null),
          _b(Icons.stop_rounded, 'STOP', cBad, connected ? onStop : null),
          const Divider(color: Colors.white12, indent: 16, endIndent: 16),
          _b(Icons.sensors, 'SENSORS', panel == 1 ? cAccent : cLo, onSensors),
          _b(Icons.insights, 'DATA', panel == 2 ? cAccent : cLo, onTelemetry),
          _b(Icons.view_in_ar, 'ROii', cLo, onArch),
          _b(Icons.sports_esports, 'MANUAL', manual ? cAccent : cLo, onManual),
        ]),
      );
  Widget _b(IconData ic, String t, Color c, VoidCallback? onTap) => InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(14),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(children: [
            Icon(ic, color: onTap == null ? cLo.withValues(alpha: 0.3) : c, size: 24),
            Text(t, style: TextStyle(color: onTap == null ? cLo.withValues(alpha: 0.3) : c, fontSize: 8, fontWeight: FontWeight.w700)),
          ])),
      );
}

class _SidePanel extends StatelessWidget {
  final AutowareState s; final int panel;
  final void Function(Map<String, dynamic>) send;
  const _SidePanel({required this.s, required this.panel, required this.send});
  @override
  Widget build(BuildContext context) => Container(
        width: 240,
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: cGlass, borderRadius: BorderRadius.circular(20)),
        child: panel == 1 ? _sensors() : _telemetry(),
      );

  Widget _sensors() {
    final roii = s.roii;
    final names = {'FrontCenterLidar': 'G32-F', 'RearCenterLidar': 'G32-R',
                   'FrontLeftLidar': 'PANDAR-L', 'FrontRightLidar': 'PANDAR-R'};
    final items = roii != null && roii['sensors'] is Map
        ? {for (final k in names.keys) names[k]!: (roii['sensors'][_rk(k)]?['status']?.toString() ?? '—')}
        : {for (final e in s.parts.entries) (names[e.key] ?? e.key): e.value};
    final base = {'LiDAR': s.sensors['lidar'] ?? '—', 'GNSS': s.sensors['gnss'] ?? '—',
                  'IMU': s.sensors['imu'] ?? '—', 'CAM': s.sensors['camera'] ?? 'OFF'};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('SENSOR SUITE', style: TextStyle(color: cLo, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      for (final e in base.entries) _row(e.key, e.value),
      if (items.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('ROii LiDAR', style: TextStyle(color: cLo, fontSize: 10, letterSpacing: 1)),
        const SizedBox(height: 4),
        for (final e in items.entries) _row(e.key, e.value),
      ],
    ]);
  }
  String _rk(String disp) => {'FrontCenterLidar': 'front_g32', 'RearCenterLidar': 'rear_g32',
      'FrontLeftLidar': 'left_pandar', 'FrontRightLidar': 'right_pandar'}[disp] ?? disp;

  Widget _telemetry() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('AUTOWARE LIVE', style: TextStyle(color: cLo, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _row('Mode', s.operationMode, s.isAutonomous ? cGood : cLo),
        _row('Localize', s.locMode, s.locMode == 'GNSS_IMU' ? cWarn : cGood),
        _row('Route', s.routeState, s.routeState == 'SET' ? cGood : cLo),
        _row('Trajectory', '${s.trajPoints} pts', s.trajPoints > 0 ? cGood : cLo),
        _row('Full route', '${s.routePath.length} pts', s.routePath.isNotEmpty ? cGood : cLo),
        _row('Steer', '${s.steerDeg.toStringAsFixed(1)}°', cHi),
        _row('Plan spd', '${s.plannedKmh.toStringAsFixed(0)} km/h', cHi),
        _row('Pos', '${s.x.toStringAsFixed(0)}, ${s.y.toStringAsFixed(0)}', cLo),
      ]);

  Widget _row(String k, String v, [Color? c]) {
    final col = c ?? (v == 'OK' ? cGood : (v == 'OFF' || v == '—' || v == 'N/A' ? cLo : cBad));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(k, style: const TextStyle(color: cLo, fontSize: 12)),
        const Spacer(),
        Text(v, style: TextStyle(color: col, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
