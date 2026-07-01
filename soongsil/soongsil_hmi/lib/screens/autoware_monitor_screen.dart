import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import '../core/js_scripts.dart';
import '../models/autoware_state.dart';
import '../providers/viewer_service_provider.dart';
import '../providers/monitor_provider.dart';
import 'widgets/drive_controls.dart';
import 'widgets/map_view.dart';
import 'architecture_screen.dart';

/// Tesla Model 3/Y v11 dashboard, wired to the live Autoware stack.
///   left third  : PRND · big speed · autopilot steering wheel · 3D vehicle ·
///                 trip rows (Tesla footer style)
///   right 2/3   : full-bleed dark nav map — tap = navigate there (the car
///                 auto-drives via the Autoware gateway); zoom stack + ETA card
///   bottom dock : icon-only Tesla dock (vehicle/architecture, manual, drive,
///                 stop, clear)
class AutowareMonitorScreen extends ConsumerStatefulWidget {
  const AutowareMonitorScreen({super.key});
  @override
  ConsumerState<AutowareMonitorScreen> createState() => _S();
}

// Tesla palette
const kBg = Color(0xFF171717);
const kPanel = Color(0xFF1B1B1B);
const kDock = Color(0xFF1B1B1B);
const kTextHi = Color(0xFFF4F4F4);
const kTextLo = Color(0xFF8E8E93);
const kBlue = Color(0xFF3E6AE1);
const kGreen = Color(0xFF2DB300);
const kRed = Color(0xFFD32F2F);

class _S extends ConsumerState<AutowareMonitorScreen> {
  bool _manual = false;
  Offset? _pendingDest;   // tapped pin awaiting confirmation (Tesla navi style)

  void _send(Map<String, dynamic> m) => ref.read(wsMonitorServiceProvider).send(m);

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(autowareStateProvider);
    final s = async.valueOrNull ?? AutowareState.disconnected();
    final connected = async.hasValue && s.locMode != 'DISCONNECTED';
    final lanes = ref.watch(lanesProvider).valueOrNull ?? const <List<double>>[];
    final polys =
        ref.watch(lanePolysProvider).valueOrNull ?? const <List<List<double>>>[];

    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        Expanded(
          child: Row(children: [
            SizedBox(width: 322, child: _LeftPanel(s: s, connected: connected)),
            Container(width: 1, color: Colors.black),
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                MapView(
                  s: s,
                  lanes: lanes,
                  polys: polys,
                  onTapWorld: (x, y) {
                    if (connected) setState(() => _pendingDest = Offset(x, y));
                  },
                ),
                // Tesla navi: tapped pin -> confirm before driving
                if (_pendingDest != null)
                  Positioned(
                    left: 0, right: 0, bottom: 70,
                    child: Center(
                      child: Material(
                        color: const Color(0xF21B1B1B),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.place, color: kRed, size: 20),
                            const SizedBox(width: 6),
                            Text(
                              '(${_pendingDest!.dx.toStringAsFixed(0)}, ${_pendingDest!.dy.toStringAsFixed(0)})',
                              style: const TextStyle(color: kTextLo, fontSize: 12),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: kBlue,
                                  padding: const EdgeInsets.symmetric(horizontal: 16)),
                              onPressed: () {
                                _send({'cmd': 'goto',
                                       'x': _pendingDest!.dx, 'y': _pendingDest!.dy});
                                setState(() => _pendingDest = null);
                              },
                              child: const Text('여기로 주행',
                                  style: TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: kTextLo, size: 18),
                              onPressed: () => setState(() => _pendingDest = null),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                if (!connected)
                  const Positioned(
                    left: 0, right: 0, top: 0, bottom: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Text('게이트웨이 연결 대기중...',
                            style: TextStyle(color: kTextLo, fontSize: 16)),
                      ),
                    ),
                  ),
                if (connected && s.routeState == 'ARRIVED')
                  Positioned(
                    left: 0, right: 0, top: 12,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                              color: kGreen, borderRadius: BorderRadius.circular(10)),
                          child: const Text('🏁 목적지 도착',
                              style: TextStyle(color: Colors.white,
                                  fontWeight: FontWeight.w800, fontSize: 14)),
                        ),
                      ),
                    ),
                  ),
                if (s.mrm.isNotEmpty)
                  Positioned(
                    left: 0, right: 0, top: 12,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                              color: kRed, borderRadius: BorderRadius.circular(10)),
                          child: Text('⚠ ${s.mrm}',
                              style: const TextStyle(color: Colors.white,
                                  fontWeight: FontWeight.w800, fontSize: 14)),
                        ),
                      ),
                    ),
                  ),
                if (s.cmdResult.isNotEmpty)
                  Positioned(
                    left: 0, right: 0, top: s.mrm.isNotEmpty ? 52 : 12,
                    child: IgnorePointer(
                        child: Center(child: _Toast(text: s.cmdResult))),
                  ),
                if (_manual)
                  Positioned(
                    left: 0, right: 0, bottom: 12,
                    child: DriveControls(
                      onChanged: (v, steer) =>
                          _send({'cmd': 'teleop', 'v': v, 'steer': steer}),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
        _Dock(
          connected: connected,
          manual: _manual,
          ndtHz: s.ndtHz,
          onArchitecture: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ArchitectureScreen())),
          onManual: () => setState(() => _manual = !_manual),
          onDrive: () => _send({'cmd': 'drive'}),
          onStop: () => _send({'cmd': 'stop'}),
          onClear: () => _send({'cmd': 'clear'}),
          onEmergency: () => _send({'cmd': 'trigger_emergency'}),
          onRespawn: () => _send({'cmd': 'respawn'}),
          onSettings: _showSettings,
        ),
      ]),
    );
  }

  // Every CARLA town the backend can bring up. drive=true => verified
  // autonomous; others come up + localize but auto-routing is shaky / map-bound.
  static const _towns = [
    ('Town01', '시내', true), ('Town02', '소도시', false),
    ('Town03', '도심', false), ('Town04', '고속', true),
    ('Town05', '대형', false), ('Town06', '직선', true),
    ('Town07', '시골', true), ('Town10HD', '도심HD', false),
  ];

  void _showSettings() {
    final ctl = TextEditingController(text: ref.read(gatewayUrlProvider));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('설정 · 맵 선택', style: TextStyle(color: kTextHi, fontSize: 16)),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('맵 (탭하면 재기동 ~4분 · PC에서 ./run.sh mapdaemon 필요)',
                  style: TextStyle(color: kTextLo, fontSize: 11)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final t in _towns)
                  _TownChip(town: t.$1, label: t.$2, drive: t.$3,
                    onTap: () { _send({'cmd': 'map', 'town': t.$1}); Navigator.pop(ctx); }),
              ]),
              const SizedBox(height: 8),
              const Text('● 초록 = 자율주행 검증됨', style: TextStyle(color: kGreen, fontSize: 10)),
              const Divider(color: Colors.white12, height: 24),
              TextField(
                controller: ctl,
                style: const TextStyle(color: kTextHi, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Gateway', labelStyle: TextStyle(color: kTextLo),
                  helperText: 'USB: ws://127.0.0.1:8765/ws',
                  helperStyle: TextStyle(color: kTextLo, fontSize: 11),
                ),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () { _send({'cmd': 'respawn'}); Navigator.pop(ctx); },
            child: const Text('리스폰')),
          TextButton(
            onPressed: () { _send({'cmd': 'fail_lidar'}); Navigator.pop(ctx); },
            child: const Text('LiDAR고장', style: TextStyle(color: kRed))),
          TextButton(
            onPressed: () { _send({'cmd': 'heal'}); Navigator.pop(ctx); },
            child: const Text('복구', style: TextStyle(color: kGreen))),
          TextButton(
            onPressed: () { _send({'cmd': 'vehicle', 'model': 'roii'}); Navigator.pop(ctx); },
            child: const Text('ROii')),
          TextButton(
            onPressed: () { _send({'cmd': 'vehicle', 'model': 'keti'}); Navigator.pop(ctx); },
            child: const Text('KETI')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
          TextButton(
            onPressed: () {
              ref.read(gatewayUrlProvider.notifier).state = ctl.text.trim();
              Navigator.pop(ctx);
            },
            child: const Text('Connect')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _LeftPanel extends ConsumerWidget {
  final AutowareState s;
  final bool connected;
  const _LeftPanel({required this.s, required this.connected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gear = !connected
        ? 'P'
        : (s.speedKmh < -0.3
            ? 'R'
            : (s.isAutonomous || s.isDriving ? 'D' : 'P'));
    return Container(
      color: kPanel,
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // --- top strip: PRND left · connectivity right (Tesla top bar) ---
        Row(children: [
          for (final g in const ['P', 'R', 'N', 'D'])
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(g,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: g == gear
                          ? kTextHi
                          : kTextLo.withValues(alpha: 0.45))),
            ),
          const Spacer(),
          Icon(connected ? Icons.usb : Icons.usb_off,
              size: 16, color: connected ? kTextLo : kRed),
        ]),
        const SizedBox(height: 4),
        // --- speed block: huge number · km/h · autopilot wheel (Tesla) ---
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.speedKmh.abs().toStringAsFixed(0),
                style: const TextStyle(
                    color: kTextHi,
                    fontSize: 72,
                    fontWeight: FontWeight.w300,
                    height: 0.95)),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(children: [
                Text(
                    s.plannedKmh > 0.5
                        ? 'km/h · plan ${s.plannedKmh.toStringAsFixed(0)}'
                        : 'km/h',
                    style: const TextStyle(color: kTextLo, fontSize: 14)),
                const SizedBox(width: 10),
                _spd(ref, Icons.remove, -10),
                const SizedBox(width: 4),
                _spd(ref, Icons.add, 10),
              ]),
            ),
          ]),
          const Spacer(),
          Column(children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              _Blinker(active: s.turn == 2, left: true),
              Transform.rotate(
                angle: -s.steerDeg * math.pi / 180 * 3,  // 실조향각 (시각 증폭 x3)
                child: _SteeringWheel(
                    engaged: s.isAutonomous,
                    ready: s.autonomousAvailable,
                    size: 44),
              ),
              _Blinker(active: s.turn == 3, left: false),
            ]),
            const SizedBox(height: 3),
            Text(
              s.isAutonomous
                  ? 'AUTOPILOT'
                  : (s.autonomousAvailable ? 'READY' : ''),
              style: TextStyle(
                  color: s.isAutonomous ? kBlue : kTextLo,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4),
            ),
          ]),
        ]),
        const SizedBox(height: 6),
        // --- 3D vehicle (Tesla render area) ---
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ModelViewer(
              backgroundColor: kPanel,
              id: 'car',
              src: 'lib/assets/roii.glb',
              alt: 'ROii',
              disablePan: true, disableTap: true, disableZoom: true,
              cameraOrbit: '-25deg 78deg 120%',
              cameraTarget: 'auto 8m auto',
              autoRotate: false,
              relatedJs: modelViewerScript,
              onWebViewCreated: (c) =>
                  ref.read(viewerServiceProvider).setController(c),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // --- trip rows (Tesla footer) ---
        _trip('Route', s.routeState, s.routeState == 'SET' ? kGreen : kTextLo),
        _trip('Trajectory', s.trajPoints > 0 ? '${s.trajPoints} pts' : '—',
            s.trajPoints > 0 ? kGreen : kTextLo),
        _trip('Mode', s.locMode,
            s.locMode == 'GNSS_IMU' ? const Color(0xFFF59E0B) : kGreen),
        _trip('NDT', '${s.ndtHz.toStringAsFixed(1)} Hz',
            s.localized ? kGreen : kRed),
        _trip('Position',
            '${s.x.toStringAsFixed(0)}, ${s.y.toStringAsFixed(0)}', kTextLo),
      ]),
    );
  }

  static double _cruise = 40;
  Widget _spd(WidgetRef ref, IconData ic, double delta) => InkWell(
        onTap: () {
          _cruise = (_cruise + delta).clamp(10, 90);
          ref.read(wsMonitorServiceProvider).send({'cmd': 'maxvel', 'kmh': _cruise});
        },
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
              color: kPanel, shape: BoxShape.circle,
              border: Border.all(color: kBlue.withValues(alpha: 0.6))),
          child: Icon(ic, size: 14, color: kBlue),
        ),
      );

  Widget _trip(String k, String v, Color c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(k, style: const TextStyle(color: kTextLo, fontSize: 11.5)),
          const Spacer(),
          Text(v,
              style: TextStyle(
                  color: c, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Turn-signal arrow (blinks at ~1 Hz when active).
class _Blinker extends StatefulWidget {
  final bool active; final bool left;
  const _Blinker({required this.active, required this.left});
  @override
  State<_Blinker> createState() => _BlinkerState();
}

class _BlinkerState extends State<_Blinker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500))
    ..repeat(reverse: true);
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: widget.active ? _c : const AlwaysStoppedAnimation(0.15),
        child: Icon(widget.left ? Icons.arrow_left : Icons.arrow_right,
            color: const Color(0xFF2DB300), size: 26),
      );
}

/// Tesla autopilot steering-wheel glyph: grey when off, blue when engaged.
class _SteeringWheel extends StatelessWidget {
  final bool engaged, ready;
  final double size;
  const _SteeringWheel(
      {required this.engaged, required this.ready, required this.size});
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _WheelPainter(
            color: engaged ? kBlue : (ready ? kTextHi : kTextLo)),
      );
}

class _WheelPainter extends CustomPainter {
  final Color color;
  _WheelPainter({required this.color});
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.085
      ..strokeCap = StrokeCap.round;
    final ctr = Offset(s.width / 2, s.height / 2);
    final r = s.width * 0.42;
    c.drawCircle(ctr, r, p);
    final ri = s.width * 0.13;
    c.drawCircle(ctr, ri, p);
    // three spokes: left, right, down
    c.drawLine(ctr + Offset(-r, 0) * 0.93, ctr + Offset(-ri, 0), p);
    c.drawLine(ctr + Offset(r, 0) * 0.93, ctr + Offset(ri, 0), p);
    c.drawLine(ctr + Offset(0, r) * 0.93, ctr + Offset(0, ri), p);
  }

  @override
  bool shouldRepaint(covariant _WheelPainter o) => o.color != color;
}

// ---------------------------------------------------------------------------

class _Dock extends StatelessWidget {
  final bool connected, manual;
  final double ndtHz;
  final VoidCallback onArchitecture, onManual, onDrive, onStop, onClear,
      onEmergency, onRespawn, onSettings;
  const _Dock(
      {required this.connected,
      required this.manual,
      required this.ndtHz,
      required this.onArchitecture,
      required this.onManual,
      required this.onDrive,
      required this.onStop,
      required this.onClear,
      required this.onEmergency,
      required this.onRespawn,
      required this.onSettings});

  @override
  Widget build(BuildContext context) {
    // Tesla dock: icon-only, evenly spaced, car icon far left.
    return Container(
      height: 58,
      color: kDock,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(children: [
        _icon(Icons.directions_car_filled, onArchitecture, color: kTextHi),
        const SizedBox(width: 18),
        Text('${ndtHz.toStringAsFixed(0)}Hz',
            style: const TextStyle(
                color: kTextLo, fontSize: 15, fontWeight: FontWeight.w600)),
        const Spacer(),
        _icon(Icons.near_me, connected ? onDrive : null, color: kBlue),
        const SizedBox(width: 34),
        _icon(Icons.stop_circle_outlined, connected ? onStop : null,
            color: kRed),
        const SizedBox(width: 34),
        _icon(Icons.wrong_location_outlined, connected ? onClear : null),
        const SizedBox(width: 34),
        // off-lane / stuck recovery -> respawn on the aligned on-lane spawn
        _icon(Icons.restart_alt, connected ? onRespawn : null, color: kTextHi),
        const Spacer(),
        // prominent EMERGENCY stop (filled red pill)
        _Emergency(onTap: connected ? onEmergency : null),
        const SizedBox(width: 18),
        _icon(Icons.sports_esports_outlined, onManual,
            color: manual ? kBlue : null),
        const SizedBox(width: 18),
        _icon(Icons.settings_outlined, onSettings),
      ]),
    );
  }

  Widget _icon(IconData ic, VoidCallback? onTap, {Color? color}) {
    final c = onTap == null
        ? kTextLo.withValues(alpha: 0.3)
        : (color ?? kTextLo);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Icon(ic, color: c, size: 29),
      ),
    );
  }
}

/// Prominent EMERGENCY-stop pill: triggers a controlled hard stop (operation
/// mode -> STOP) and the tablet shows a red EMERGENCY banner until heal/drive.
class _Emergency extends StatelessWidget {
  final VoidCallback? onTap;
  const _Emergency({required this.onTap});
  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return Material(
      color: on ? kRed : kRed.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
            SizedBox(width: 6),
            Text('EMERGENCY',
                style: TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w900, letterSpacing: 0.5)),
          ]),
        ),
      ),
    );
  }
}

/// One tappable town tile in the map selector. Green ring = verified drivable.
class _TownChip extends StatelessWidget {
  final String town, label;
  final bool drive;
  final VoidCallback onTap;
  const _TownChip(
      {required this.town, required this.label, required this.drive, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 94,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: drive ? kGreen.withValues(alpha: 0.7) : Colors.white24),
          ),
          child: Column(children: [
            Text(label,
                style: TextStyle(
                    color: drive ? kGreen : kTextHi,
                    fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(town, style: const TextStyle(color: kTextLo, fontSize: 10)),
          ]),
        ),
      );
}

class _Toast extends StatelessWidget {
  final String text;
  const _Toast({required this.text});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
            color: const Color(0xE61B1B1B),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white10)),
        child: Text(text,
            style: const TextStyle(color: kTextHi, fontSize: 12.5)),
      );
}
