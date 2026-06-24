import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/autoware_state.dart';
import '../providers/monitor_provider.dart';
import 'widgets/map_view.dart';
import 'widgets/osm_map_view.dart';
import 'widgets/drive_controls.dart';
import 'widgets/surround_view_3d.dart';

/// AWSIM Tesla — a proper Tesla-style autonomous-driving dashboard for the
/// AWSIM (Nishi-Shinjuku) simulation. The centerpiece is a live 3D surround
/// view (Three.js in a WebView): the ego car model + the real road + the
/// surrounding AWSIM NPC vehicles as 3D shapes coloured by class. A clean HUD
/// (large speed, PRND, AUTOPILOT/READY pill, MRM banner) overlays the 3D scene;
/// a small navigation map sits beside it (Tesla-style), and a minimal control
/// bar (DRIVE/STOP + camera) runs along the bottom. Light/white "tabsla" theme.
class NiroCommandScreen extends ConsumerStatefulWidget {
  const NiroCommandScreen({super.key});

  @override
  ConsumerState<NiroCommandScreen> createState() => _NiroCommandScreenState();
}

class _NiroCommandScreenState extends ConsumerState<NiroCommandScreen> {
  bool _manual = false;
  bool _showCam = false;
  Offset? _pendingDest; // tapped destination awaiting confirm
  DateTime? _lastRx;    // wall-clock time of the last status frame received

  // --- palette (light / white "tabsla" Tesla aesthetic) ---
  static const _bg = Color(0xFFEEF2F7);
  static const _panel = Colors.white;
  static const _accent = Color(0xFF2563EB);
  static const _green = Color(0xFF16A34A);
  static const _red = Color(0xFFDC2626);
  static const _ink = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);

  void _send(Map<String, dynamic> msg) =>
      ref.read(wsMonitorServiceProvider).send(msg);

  @override
  Widget build(BuildContext context) {
    // Track when the most recent live frame arrived (for the stale indicator).
    ref.listen(autowareStateProvider, (prev, next) {
      next.whenData((s) {
        if (s.operationMode != 'DISCONNECTED') {
          setState(() => _lastRx = DateTime.now());
        }
      });
    });

    final stateAsync = ref.watch(autowareStateProvider);
    final lanes = ref.watch(lanesProvider).valueOrNull ?? const [];
    final polys = ref.watch(lanePolysProvider).valueOrNull ?? const [];

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Stack(
          children: [
            stateAsync.when(
              loading: () => _connecting(),
              error: (_, _) => _connecting(),
              data: (s) {
                if (s.operationMode == 'DISCONNECTED' &&
                    s.locMode == 'DISCONNECTED') {
                  return _connecting();
                }
                return _cockpit(s, lanes, polys);
              },
            ),
            // settings gear (top-right) — gateway URL + connection status
            Positioned(
              top: 16,
              right: 16,
              child: _gearButton(),
            ),
          ],
        ),
      ),
    );
  }

  // ===================================================================
  //  Cockpit: dominant 3D surround view (left) + nav map PIP (right)
  // ===================================================================
  Widget _cockpit(AutowareState s,
      List<List<double>> lanes, List<List<List<double>>> polys) {
    final cam = ref.watch(cameraProvider).valueOrNull;
    final readOnly = s.readOnly;

    void onTap(double x, double y) {
      if (readOnly) return;
      setState(() => _pendingDest = Offset(x, y));
    }

    // The small navigation map (Tesla shows nav beside the car). Real-map mode
    // uses the OSM basemap, otherwise the synthetic top-down map.
    final map = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: s.site != null
          ? OsmMapView(s: s, polys: polys, onTapWorld: onTap)
          : MapView(s: s, lanes: lanes, polys: polys, light: true, onTapWorld: onTap),
    );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- LEFT: the Tesla 3D surround view (centerpiece) + HUD ---
                Expanded(
                  flex: 7,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Stack(
                      children: [
                        Positioned.fill(child: SurroundView3D(s: s, polys: polys)),
                        // large speed HUD (top-left)
                        Positioned(left: 14, top: 14, child: _SpeedHud(s: s)),
                        // mode pill (top-center)
                        Positioned(
                          top: 14, left: 0, right: 0,
                          child: Center(child: _StatusPill(s: s)),
                        ),
                        // MRM red banner
                        if (s.mrm.isNotEmpty)
                          Positioned(
                            left: 0, right: 0, top: 72,
                            child: Center(child: _mrmBanner(s.mrm)),
                          ),
                        // connection / stale indicator (bottom-left)
                        Positioned(
                          left: 14, bottom: 14,
                          child: _ConnPill(s: s, lastRx: _lastRx),
                        ),
                        // manual driving controls overlaid at the bottom
                        if (_manual && !readOnly)
                          Positioned(
                            left: 0, right: 0, bottom: 10,
                            child: DriveControls(
                              onChanged: (v, steer) =>
                                  _send({'cmd': 'teleop', 'v': v, 'steer': steer}),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // --- RIGHT: navigation map (secondary panel) ---
                Expanded(
                  flex: 4,
                  child: Stack(
                    children: [
                      Positioned.fill(child: map),
                      // camera toggle (top-right of the map)
                      Positioned(
                        top: 10, right: 10,
                        child: _iconBtn(
                          _showCam
                              ? Icons.videocam_off_rounded
                              : Icons.videocam_rounded,
                          () => setState(() => _showCam = !_showCam),
                        ),
                      ),
                      if (_showCam)
                        Positioned(top: 54, right: 10, child: _camPopup(cam)),
                      // tap-to-drive confirm bubble
                      if (_pendingDest != null)
                        Positioned(
                          left: 0, right: 0, bottom: 16,
                          child: Center(child: _confirmBubble()),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          readOnly ? _readOnlyBar(s) : _controlBar(s),
        ],
      ),
    );
  }

  // ----- camera popup (live front-camera JPEG from the gateway) -----
  Widget _camPopup(Uint8List? cam) => Container(
        width: 240, height: 144,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12),
          ],
          border: Border.all(color: const Color(0xFFE2E7ED)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Stack(fit: StackFit.expand, children: [
            if (cam != null)
              Image.memory(cam, gaplessPlayback: true, fit: BoxFit.cover)
            else
              const ColoredBox(
                color: _bg,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.videocam_off_rounded, color: _muted, size: 28),
                    SizedBox(height: 6),
                    Text('전방 카메라 대기',
                        style: TextStyle(
                            color: _ink, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            Positioned(
              top: 6, left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.black54, borderRadius: BorderRadius.circular(5)),
                child: const Text('FRONT',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1)),
              ),
            ),
          ]),
        ),
      );

  Widget _iconBtn(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        elevation: 1.5,
        shadowColor: Colors.black26,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, size: 18, color: _ink)),
        ),
      );

  Widget _gearButton() {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _openSettings,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.settings_rounded, color: _muted, size: 22),
        ),
      ),
    );
  }

  void _openSettings() {
    final current = ref.read(gatewayUrlProvider);
    final controller = TextEditingController(text: current);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 22, right: 22, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 22,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: const [
                Icon(Icons.lan_rounded, color: _accent, size: 22),
                SizedBox(width: 8),
                Text('게이트웨이 연결 설정',
                    style: TextStyle(
                        color: _ink, fontSize: 18, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'WebSocket URL',
                  hintText: 'ws://127.0.0.1:8765/ws',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 8),
              const Text('USB 연결은 127.0.0.1, Wi-Fi는 ws://<PC-IP>:8765/ws 사용',
                  style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _quickUrl(controller, 'AWSIM (USB)', 'ws://127.0.0.1:8765/ws'),
                  _quickUrl(controller, 'HMI 8766', 'ws://127.0.0.1:8766/ws'),
                  _quickUrl(controller, 'Wi-Fi', 'ws://192.168.0.10:8765/ws'),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('취소', style: TextStyle(color: _muted)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        final url = controller.text.trim();
                        if (url.isNotEmpty) {
                          ref.read(gatewayUrlProvider.notifier).state = url;
                          setState(() => _lastRx = null);
                        }
                        Navigator.pop(ctx);
                      },
                      child: const Text('저장 & 재연결'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _quickUrl(TextEditingController c, String label, String url) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: _accent.withValues(alpha: 0.08),
      side: BorderSide(color: _accent.withValues(alpha: 0.25)),
      labelStyle: const TextStyle(color: _accent, fontWeight: FontWeight.w700),
      onPressed: () => c.text = url,
    );
  }

  Widget _connecting() {
    final url = ref.watch(gatewayUrlProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 38,
            height: 38,
            child: CircularProgressIndicator(strokeWidth: 3, color: _accent),
          ),
          const SizedBox(height: 22),
          const Text('연결 대기 중…',
              style: TextStyle(
                  color: _ink, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(url,
              style: const TextStyle(
                  color: _muted, fontSize: 14, fontFamily: 'monospace')),
          const SizedBox(height: 4),
          const Text('AWSIM 자율주행 게이트웨이에 연결 중',
              style: TextStyle(color: _muted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _mrmBanner(String mrm) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: _red,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: _red.withValues(alpha: 0.4), blurRadius: 16)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 10),
        Text('MRM · $mrm',
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 15,
                letterSpacing: 0.5)),
      ]),
    );
  }

  Widget _confirmBubble() {
    final d = _pendingDest!;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.place, color: _red, size: 20),
        const SizedBox(width: 8),
        Text('여기로 주행할까요?  (${d.dx.toStringAsFixed(0)}, ${d.dy.toStringAsFixed(0)})',
            style: const TextStyle(
                color: _ink, fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () => setState(() => _pendingDest = null),
          child: const Text('취소', style: TextStyle(color: _muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: _accent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          onPressed: () {
            _send({'cmd': 'goto', 'x': d.dx, 'y': d.dy});
            setState(() => _pendingDest = null);
          },
          child: const Text('주행'),
        ),
      ]),
    );
  }

  Widget _controlBar(AutowareState s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          _bigBtn(
            label: s.isAutonomous ? 'STOP' : 'DRIVE',
            icon: s.isAutonomous ? Icons.stop_rounded : Icons.play_arrow_rounded,
            color: s.isAutonomous ? _red : _green,
            onTap: () => _send({'cmd': s.isAutonomous ? 'stop' : 'drive'}),
          ),
          const SizedBox(width: 10),
          _bigBtn(
            label: 'MANUAL',
            icon: Icons.sports_esports_rounded,
            color: _manual ? _accent : _muted,
            filled: _manual,
            onTap: () {
              setState(() => _manual = !_manual);
              if (!_manual) _send({'cmd': 'teleop', 'v': 0.0, 'steer': 0.0});
            },
          ),
          const SizedBox(width: 10),
          _bigBtn(
            label: 'CLEAR',
            icon: Icons.layers_clear_rounded,
            color: _muted,
            onTap: () => _send({'cmd': 'clear'}),
          ),
          const Spacer(),
          // live status pills
          _StatPill(label: 'ROUTE', value: s.routeState, ok: s.routeState == 'SET'),
          _StatPill(label: 'TRAJ', value: '${s.trajPoints}', ok: s.trajPoints > 0),
          _StatPill(
              label: 'NDT',
              value: '${s.ndtHz.toStringAsFixed(0)}Hz',
              ok: s.ndtHz > 1),
          _StatPill(label: 'OBJ', value: '${s.objects.length}', ok: s.objects.isNotEmpty),
          const SizedBox(width: 10),
          _bigBtn(
            label: 'EMERGENCY',
            icon: Icons.priority_high_rounded,
            color: _red,
            filled: true,
            onTap: () => _send({'cmd': 'trigger_emergency'}),
          ),
        ],
      ),
    );
  }

  // Read-only HMI: status readout strip instead of control buttons.
  Widget _readOnlyBar(AutowareState s) {
    final loc = s.hmiLoc ?? const {};
    String pct(dynamic v) =>
        (v is num) ? '${(v * 100).toStringAsFixed(0)}%' : '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _roPill('PROFILE', s.profile ?? '—'),
          _roPill('SOURCE', s.isRealVehicle ? '실차' : (s.hmiSource ?? 'simulation')),
          _roPill('MODE', _displayStr(s.operationMode)),
          _roPill('ROUTE', _displayStr(s.routeState)),
          _roPill('MRM', s.mrm.isEmpty ? '—' : s.mrm),
          const SizedBox(width: 6),
          _roPill('측위', _displayStr(loc['mode']?.toString())),
          _roPill('LiDAR w', pct(loc['lidarWeight'])),
          _roPill('GNSS w', pct(loc['gnssWeight'])),
          _roPill('OBJ', '${s.objects.length}'),
        ]),
      ),
    );
  }

  String _displayStr(String? v) {
    if (v == null || v.isEmpty) return '—';
    if (v == 'UNAVAILABLE') return 'N/A';
    return v;
  }

  Widget _roPill(String label, String value) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: _muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
          const SizedBox(height: 1),
          Text(value,
              style: const TextStyle(
                  color: _ink, fontSize: 13, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _bigBtn({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return Material(
      color: filled ? color : color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: filled ? Colors.white : color, size: 22),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      color: filled ? Colors.white : color,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3)),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
//  Speed HUD
// ===========================================================================
class _SpeedHud extends StatelessWidget {
  final AutowareState s;
  const _SpeedHud({required this.s});

  @override
  Widget build(BuildContext context) {
    final prnd = s.isAutonomous
        ? 'D'
        : (s.speedKmh < -0.3 ? 'R' : (s.speedKmh.abs() < 0.3 ? 'P' : 'D'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 14)],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(s.speedKmh.abs().toStringAsFixed(0),
              style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 52,
                  height: 1.0,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('km/h',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 16)),
          ),
          const SizedBox(width: 16),
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(prnd,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
//  Mode status pill (top-center)
// ===========================================================================
class _StatusPill extends StatelessWidget {
  final AutowareState s;
  const _StatusPill({required this.s});

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color color;
    late final IconData icon;
    if (s.isAutonomous) {
      label = 'AUTOPILOT';
      color = const Color(0xFF2563EB);
      icon = Icons.auto_mode_rounded;
    } else if (s.autonomousAvailable) {
      label = 'READY';
      color = const Color(0xFF16A34A);
      icon = Icons.check_circle_rounded;
    } else {
      label = 'MANUAL';
      color = const Color(0xFF64748B);
      icon = Icons.pan_tool_alt_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 14)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0)),
        const SizedBox(width: 8),
        Text('· ${s.operationMode}',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), fontSize: 12)),
      ]),
    );
  }
}

// ===========================================================================
//  Connection / staleness pill
// ===========================================================================
class _ConnPill extends StatelessWidget {
  final AutowareState s;
  final DateTime? lastRx;
  const _ConnPill({required this.s, required this.lastRx});

  @override
  Widget build(BuildContext context) {
    final ageMs = lastRx == null
        ? null
        : DateTime.now().difference(lastRx!).inMilliseconds;
    final localStale = ageMs != null && ageMs > 3000;
    final stale = s.dataStale || localStale;
    final c = stale ? const Color(0xFFDC2626) : const Color(0xFF16A34A);
    final ageTxt = ageMs == null
        ? '—'
        : (ageMs < 1000 ? '${ageMs}ms' : '${(ageMs / 1000).toStringAsFixed(1)}s');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
            color: c, shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 8),
        Text(stale ? '연결 끊김' : '연결됨',
            style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(width: 6),
        Text('· $ageTxt 전',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
      ]),
    );
  }
}

// ===========================================================================
//  Small status pill (bottom bar)
// ===========================================================================
class _StatPill extends StatelessWidget {
  final String label, value;
  final bool ok;
  const _StatPill({required this.label, required this.value, required this.ok});

  @override
  Widget build(BuildContext context) {
    final c = ok ? const Color(0xFF16A34A) : const Color(0xFF94A3B8);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
          const SizedBox(height: 1),
          Text(value,
              style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
