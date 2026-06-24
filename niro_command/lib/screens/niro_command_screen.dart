import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/autoware_state.dart';
import '../providers/monitor_provider.dart';
import 'widgets/map_view.dart';
import 'widgets/osm_map_view.dart';
import 'widgets/drive_controls.dart';

/// Premium light/white Tesla-grade cockpit for the Niro autonomous-driving demo.
/// Dominant live map (center/right) with a clean HUD; left panel is the
/// signature Niro Dual-Localization (이중측위) status; bottom control bar.
class NiroCommandScreen extends ConsumerStatefulWidget {
  const NiroCommandScreen({super.key});

  @override
  ConsumerState<NiroCommandScreen> createState() => _NiroCommandScreenState();
}

class _NiroCommandScreenState extends ConsumerState<NiroCommandScreen> {
  bool _manual = false;
  Offset? _pendingDest; // tapped destination awaiting confirm

  // --- palette ---
  static const _bg = Color(0xFFEFF2F6);
  static const _panel = Colors.white;
  static const _accent = Color(0xFF2563EB);
  static const _green = Color(0xFF16A34A);
  static const _red = Color(0xFFDC2626);
  static const _amber = Color(0xFFF59E0B);
  static const _ink = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);

  void _send(Map<String, dynamic> msg) =>
      ref.read(wsMonitorServiceProvider).send(msg);

  @override
  Widget build(BuildContext context) {
    final stateAsync = ref.watch(autowareStateProvider);
    final lanes = ref.watch(lanesProvider).valueOrNull ?? const [];
    final polys = ref.watch(lanePolysProvider).valueOrNull ?? const [];

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: stateAsync.when(
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
      ),
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
              style: const TextStyle(color: _muted, fontSize: 14, fontFamily: 'monospace')),
          const SizedBox(height: 4),
          const Text('Niro 자율주행 게이트웨이에 연결 중',
              style: TextStyle(color: _muted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _cockpit(AutowareState s,
      List<List<double>> lanes, List<List<List<double>>> polys) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- LEFT: Niro Dual-Localization panel ---
          SizedBox(width: 330, child: _NiroPanel(s: s, send: _send)),
          const SizedBox(width: 12),
          // --- CENTER/RIGHT: map + HUD + controls ---
          Expanded(child: _mapColumn(s, lanes, polys)),
        ],
      ),
    );
  }

  Widget _mapColumn(AutowareState s,
      List<List<double>> lanes, List<List<List<double>>> polys) {
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              children: [
                Positioned.fill(
                  child: s.site != null
                      // real-map mode: OpenStreetMap basemap
                      ? OsmMapView(
                          s: s,
                          polys: polys,
                          onTapWorld: (x, y) {
                            setState(() => _pendingDest = Offset(x, y));
                          },
                        )
                      // CARLA / Town mode: synthetic top-down map
                      : MapView(
                          s: s,
                          lanes: lanes,
                          polys: polys,
                          light: true,
                          onTapWorld: (x, y) {
                            setState(() => _pendingDest = Offset(x, y));
                          },
                        ),
                ),
                // top HUD
                Positioned(
                  left: 14,
                  top: 14,
                  child: _SpeedHud(s: s),
                ),
                Positioned(
                  top: 14,
                  left: 0,
                  right: 0,
                  child: Center(child: _StatusPill(s: s)),
                ),
                // MRM red banner
                if (s.mrm.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 70,
                    child: Center(child: _mrmBanner(s.mrm)),
                  ),
                // tap-to-drive confirm bubble
                if (_pendingDest != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 18,
                    child: Center(child: _confirmBubble()),
                  ),
                // manual driving controls overlaid at the bottom
                if (_manual)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: DriveControls(
                      onChanged: (v, steer) =>
                          _send({'cmd': 'teleop', 'v': v, 'steer': steer}),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _controlBar(s),
      ],
    );
  }

  Widget _mrmBanner(String mrm) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: _red,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: _red.withValues(alpha: 0.4), blurRadius: 16),
        ],
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
                color: _ink, fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(width: 14),
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
    final niro = s.niro;
    final injected = niro != null && niro['injected'] == true;
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
          const SizedBox(width: 10),
          _bigBtn(
            label: 'RESPAWN',
            icon: Icons.restart_alt_rounded,
            color: _muted,
            onTap: () => _send({'cmd': 'respawn'}),
          ),
          const SizedBox(width: 10),
          _bigBtn(
            label: injected ? 'HEAL LiDAR' : 'FAULT LiDAR',
            icon: injected
                ? Icons.healing_rounded
                : Icons.sensors_off_rounded,
            color: injected ? _green : _amber,
            filled: injected,
            onTap: () => _send({'cmd': injected ? 'heal' : 'fail_lidar'}),
          ),
          const Spacer(),
          // live status pills
          _StatPill(
              label: 'ROUTE', value: s.routeState, ok: s.routeState == 'SET'),
          _StatPill(
              label: 'TRAJ',
              value: '${s.trajPoints}',
              ok: s.trajPoints > 0),
          _StatPill(
              label: 'NDT',
              value: '${s.ndtHz.toStringAsFixed(0)}Hz',
              ok: s.ndtHz > 1),
          _StatPill(
              label: 'OBJ',
              value: '${s.objects.length}',
              ok: s.objects.isNotEmpty),
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
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 14),
        ],
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
//  Small status pill (bottom bar)
// ===========================================================================
class _StatPill extends StatelessWidget {
  final String label, value;
  final bool ok;
  const _StatPill(
      {required this.label, required this.value, required this.ok});

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
              style: TextStyle(
                  color: c, fontSize: 13, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

// ===========================================================================
//  Niro Dual-Localization panel (signature feature)
// ===========================================================================
class _NiroPanel extends StatelessWidget {
  final AutowareState s;
  final void Function(Map<String, dynamic>) send;
  const _NiroPanel({required this.s, required this.send});

  static const _accent = Color(0xFF2563EB);
  static const _green = Color(0xFF16A34A);
  static const _red = Color(0xFFDC2626);
  static const _ink = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);

  @override
  Widget build(BuildContext context) {
    final niro = s.niro;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 18, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: niro != null
          ? _content(niro)                       // CARLA niro / real-vehicle: real 이중측위
          : (s.site != null ? _navPanel() : _placeholder()),  // real-map planning_sim: navigation/측위
    );
  }

  // Real-map (planning_sim) mode: 이중측위 has no sensors to fuse, so show what IS
  // real here — localization status, site, route progress, speed, MRM. Honest:
  // LiDAR/GNSS 이중측위 is the CARLA/real-vehicle feature (noted at the bottom).
  Widget _navPanel() {
    final site = (s.site?['site'] ?? '').toString();
    final siteName = site.startsWith('pangyo') ? '판교'
        : site.startsWith('soongsil') ? '숭실대'
        : site.startsWith('kcity') ? 'K-City' : site;
    // distance to goal = ego -> last route point (straight-line estimate)
    double dist = 0;
    if (s.routePath.isNotEmpty) {
      final g = s.routePath.last;
      dist = math.sqrt(math.pow(g[0] - s.x, 2) + math.pow(g[1] - s.y, 2));
    }
    final driving = s.operationMode == 'AUTONOMOUS';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(Icons.navigation_rounded, color: _accent, size: 22),
            SizedBox(width: 8),
            Text('Niro 측위 · 내비게이션',
                style: TextStyle(color: _ink, fontSize: 19, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 16),
          _navRow('측위 상태', s.localized ? '정상 (수렴)' : '초기화 중',
              s.localized ? _green : _muted),
          _navRow('측위원', 'planning_sim · 완벽측위', _accent),
          _navRow('지도', '$siteName · NGII 정밀(3D)', _ink),
          const Divider(height: 26),
          _navRow('주행 모드', driving ? 'AUTONOMOUS' : s.operationMode,
              driving ? _green : _muted),
          _navRow('경로', _routeKo(s.routeState), _ink),
          if (dist > 1) _navRow('목적지까지', '${dist.toStringAsFixed(0)} m', _accent),
          _navRow('궤적 점', '${s.trajPoints}', s.trajPoints > 0 ? _green : _muted),
          _navRow('속도', '${s.speedKmh.toStringAsFixed(0)} km/h', _ink),
          const SizedBox(height: 14),
          const Text('MRM · 최소위험기동',
              style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _MrmLadder(mrm: s.mrm),
          const Divider(height: 26),
          _mapSwitch(site),
          const Divider(height: 26),
          _systemMonitor(),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(10)),
            child: const Text(
                'LiDAR/GNSS 이중측위는 CARLA·실차 모드에서 표시됩니다\n(planning_sim은 센서 없는 검증용)',
                style: TextStyle(color: _muted, fontSize: 11, height: 1.4)),
          ),
        ],
      ),
    );
  }

  // --- 지도 전환 ---------------------------------------------------------
  Widget _mapSwitch(String currentSite) {
    const maps = [
      ('판교도심', 'pangyo_zc'),   // 판교제로시티 (NGII 정밀, 3D 도심)
      ('K-City', 'kcity'),         // 자동차안전연구원 시험장 (NGII 정밀, 3D)
      ('판교시범', 'pangyo_ngii'), // 자율주행시범지구 (NGII 3D)
      ('Town04', 'Town04'),        // CARLA Town
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('지도 전환',
            style: TextStyle(
                color: _muted, fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in maps)
              _mapChip(m.$1, m.$2, _isCurrentMap(currentSite, m.$2)),
          ],
        ),
        const SizedBox(height: 6),
        const Text('전환 시 ~3분 재기동',
            style: TextStyle(color: _muted, fontSize: 10)),
      ],
    );
  }

  bool _isCurrentMap(String current, String town) => current == town;

  Widget _mapChip(String label, String town, bool active) {
    return Material(
      color: active ? _accent : _accent.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => send({'cmd': 'map', 'town': town}),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(label,
              style: TextStyle(
                  color: active ? Colors.white : _accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  // --- 시스템 실시간 -----------------------------------------------------
  Widget _systemMonitor() {
    final sys = s.system;
    final nodes = (sys?['nodes'] is num) ? (sys!['nodes'] as num).toInt() : null;
    final topics = (sys?['topics'] is List) ? sys!['topics'] as List : const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('시스템 실시간',
              style: TextStyle(
                  color: _muted, fontSize: 11, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (nodes != null)
            Text('노드 $nodes개',
                style: const TextStyle(
                    color: _ink, fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        if (topics.isEmpty)
          const Text('대기 중…',
              style: TextStyle(color: _muted, fontSize: 12))
        else
          for (final t in topics)
            if (t is Map) _sysRow(t),
      ],
    );
  }

  Widget _sysRow(Map t) {
    final ok = t['ok'] == true;
    final c = ok ? _green : _red;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text((t['n'] ?? '').toString(),
              style: const TextStyle(
                  color: _ink, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Text((t['v'] ?? '').toString(),
            style: const TextStyle(
                color: _muted, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _navRow(String k, String v, Color c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(k, style: const TextStyle(color: _muted, fontSize: 14, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(v, style: TextStyle(color: c, fontSize: 14.5, fontWeight: FontWeight.w800)),
        ]),
      );

  String _routeKo(String st) => st == 'SET' ? '설정됨'
      : st == 'ARRIVED' ? '도착'
      : st.contains('CHANG') ? '변경중'
      : st == 'UNSET' ? '대기' : st;

  Widget _header() {
    return Row(
      children: const [
        Icon(Icons.hub_rounded, color: _accent, size: 22),
        SizedBox(width: 8),
        Text('Niro 이중측위',
            style: TextStyle(
                color: _ink, fontSize: 19, fontWeight: FontWeight.w800)),
      ],
    );
  }

  Widget _placeholder() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const Spacer(),
        Center(
          child: Column(
            children: [
              Icon(Icons.satellite_alt_rounded,
                  size: 56, color: _muted.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              const Text('Niro 이중측위 대기 중',
                  style: TextStyle(
                      color: _muted, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('데모를 시작하면\nLiDAR / GNSS 융합 상태가 표시됩니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, fontSize: 12, height: 1.5)),
            ],
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _content(Map<String, dynamic> n) {
    final fault = n['mode'] == 'lidar_fault';
    final valid = n['valid'] == true;
    final lw = _d(n['lidar_weight']);
    final gw = _d(n['gnss_weight']);
    final lfresh = n['lidar_fresh'] == true;
    final gfresh = n['gnss_fresh'] == true;
    final gap = _d(n['pipeline_gap_m']);
    final sensors = (n['sensors'] ?? {}) as Map;
    final ouster = (sensors['ouster_os2_128'] ?? {}) as Map;
    final gnss = (sensors['rtk_gnss'] ?? {}) as Map;
    final imu = (sensors['imu'] ?? {}) as Map;
    final ev = n['lastEvent'] is Map ? n['lastEvent'] as Map : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: 12),
        // mode pill
        _modePill(fault, valid),
        const SizedBox(height: 16),
        // weight bars
        _WeightBar(
          label: 'LiDAR · Ouster OS2-128',
          weight: lw,
          color: fault ? const Color(0xFF94A3B8) : _accent,
          fresh: lfresh,
        ),
        const SizedBox(height: 10),
        _WeightBar(
          label: 'RTK-GNSS',
          weight: gw,
          color: fault ? _green : const Color(0xFF22C55E),
          fresh: gfresh,
        ),
        const SizedBox(height: 16),
        const Text('센서 상태',
            style: TextStyle(
                color: _muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        _sensorRow('Ouster OS2-128', ouster['ok'] == true,
            '${_d(ouster['hz']).toStringAsFixed(0)} Hz'),
        _sensorRow('RTK-GNSS', gnss['ok'] == true,
            (gnss['fix'] ?? '-').toString()),
        _sensorRow('IMU', imu['ok'] == true, ''),
        const SizedBox(height: 12),
        // pipeline gap
        Row(children: [
          const Icon(Icons.straighten_rounded, size: 16, color: _muted),
          const SizedBox(width: 6),
          const Text('파이프라인 갭',
              style: TextStyle(color: _muted, fontSize: 12)),
          const Spacer(),
          Text('${gap.toStringAsFixed(2)} m',
              style: TextStyle(
                  color: gap > 0.5 ? _red : _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800)),
        ]),
        if (ev != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.bolt_rounded, size: 15, color: Color(0xFFB45309)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    '전환 ${ev['from']} → ${ev['to']}  '
                    '(Δ${_d(ev['pos_jump_m']).toStringAsFixed(2)}m, '
                    'Δ${_d(ev['yaw_jump_rad']).toStringAsFixed(2)}rad)',
                    style: const TextStyle(
                        color: Color(0xFF92400E), fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ],
        if (s.system != null) ...[
          const SizedBox(height: 14),
          _systemMonitor(),
        ],
        const Spacer(),
        // MRM ladder
        const Text('MRM 단계',
            style: TextStyle(
                color: _muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        _MrmLadder(mrm: s.mrm),
      ],
    );
  }

  Widget _modePill(bool fault, bool valid) {
    final c = fault ? _red : _green;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Row(children: [
        Icon(fault ? Icons.error_rounded : Icons.verified_rounded,
            color: c, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            fault ? '라이다 결함 → GNSS 폴백' : '정상 · LiDAR + GNSS',
            style: TextStyle(
                color: c, fontSize: 15, fontWeight: FontWeight.w800),
          ),
        ),
        if (!valid)
          const Text('INVALID',
              style: TextStyle(
                  color: _red, fontSize: 10, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _sensorRow(String name, bool ok, String extra) {
    final c = ok ? _green : _red;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(name,
              style: const TextStyle(
                  color: _ink, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        if (extra.isNotEmpty)
          Text(extra,
              style: const TextStyle(
                  color: _muted, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  static double _d(dynamic v) => (v is num) ? v.toDouble() : 0.0;
}

// ===========================================================================
//  Animated weight bar
// ===========================================================================
class _WeightBar extends StatelessWidget {
  final String label;
  final double weight; // 0..1
  final Color color;
  final bool fresh;
  const _WeightBar(
      {required this.label,
      required this.weight,
      required this.color,
      required this.fresh});

  @override
  Widget build(BuildContext context) {
    final w = weight.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
          if (!fresh)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Text('STALE',
                  style: TextStyle(
                      color: Color(0xFFDC2626),
                      fontSize: 9,
                      fontWeight: FontWeight.w800)),
            ),
          Text('${(w * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(children: [
            Container(height: 12, color: const Color(0xFFE2E8F0)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: w),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (ctx, v, _) => FractionallySizedBox(
                widthFactor: v,
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [color.withValues(alpha: 0.7), color],
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ],
    );
  }
}

// ===========================================================================
//  MRM ladder: 정상 / 서행 / 비상정지 / 갓길정차
// ===========================================================================
class _MrmLadder extends StatelessWidget {
  final String mrm;
  const _MrmLadder({required this.mrm});

  @override
  Widget build(BuildContext context) {
    // active level: 0 normal, 1 slow, 2 emergency stop, 3 pull-over
    final m = mrm.toUpperCase();
    int level = 0;
    if (m.isEmpty || m == 'NORMAL' || m == 'NONE') {
      level = 0;
    } else if (m.contains('COMFORT') || m.contains('SLOW')) {
      level = 1;
    } else if (m.contains('PULL') || m.contains('SHOULDER')) {
      level = 3;
    } else if (m.contains('EMERGENCY') || m.contains('STOP')) {
      level = 2;
    } else {
      level = 2;
    }

    const labels = ['정상', '서행', '비상정지', '갓길정차'];
    const colors = [
      Color(0xFF16A34A),
      Color(0xFFF59E0B),
      Color(0xFFDC2626),
      Color(0xFF7C3AED),
    ];

    return Row(
      children: List.generate(4, (i) {
        final active = i == level;
        return Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? colors[i]
                  : colors[i].withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
              boxShadow: active
                  ? [BoxShadow(color: colors[i].withValues(alpha: 0.45), blurRadius: 10)]
                  : null,
            ),
            child: Column(children: [
              Icon(
                  i == 0
                      ? Icons.check_rounded
                      : i == 1
                          ? Icons.slow_motion_video_rounded
                          : i == 2
                              ? Icons.stop_circle_rounded
                              : Icons.local_parking_rounded,
                  size: 16,
                  color: active ? Colors.white : colors[i]),
              const SizedBox(height: 3),
              Text(labels[i],
                  style: TextStyle(
                      color: active ? Colors.white : colors[i],
                      fontSize: 10,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
        );
      }),
    );
  }
}
