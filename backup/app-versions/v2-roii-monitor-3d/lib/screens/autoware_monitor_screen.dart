import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import '../core/js_scripts.dart';
import '../core/constants.dart';
import '../models/autoware_state.dart';
import '../providers/viewer_service_provider.dart';
import '../providers/monitor_provider.dart';
import 'widgets/status_overlay.dart';
import 'widgets/drive_controls.dart';

/// Live monitor: ROii 3D model (pleos base) + Autoware autonomous state overlay,
/// fed by the ROS gateway over WebSocket. Manual teleop via tilt + pedals.
class AutowareMonitorScreen extends ConsumerStatefulWidget {
  const AutowareMonitorScreen({super.key});
  @override
  ConsumerState<AutowareMonitorScreen> createState() => _S();
}

class _S extends ConsumerState<AutowareMonitorScreen> {
  final Set<String> _activeFaults = {};
  bool _jsReady = false;

  Future<void> _waitForJs(service) async {
    for (int i = 0; i < 25; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (await service.isJsReady()) {
        await service.initializeLabelHotspots();
        await service.toggleHotspots(true);
        _jsReady = true;
        return;
      }
    }
    _jsReady = true;
  }

  void _applyFaults(List<String> faults) {
    if (!_jsReady) return;
    final service = ref.read(viewerServiceProvider);
    final next = faults.toSet();
    for (final f in next.difference(_activeFaults)) {
      final cfg = errorHotspotConfigs[f];
      if (cfg != null) service.showFaultAlert(f, 2, cfg);
    }
    for (final f in _activeFaults.difference(next)) {
      service.hideFaultAlert(f);
    }
    _activeFaults..clear()..addAll(next);
  }

  void _send(Map<String, dynamic> m) => ref.read(wsMonitorServiceProvider).send(m);

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AutowareState>>(autowareStateProvider, (prev, next) {
      next.whenData((s) => _applyFaults(s.faults));
    });
    final async = ref.watch(autowareStateProvider);
    final s = async.valueOrNull ?? AutowareState.disconnected();
    final connected = async.hasValue && s.locMode != 'DISCONNECTED';

    return Scaffold(
      backgroundColor: const Color(0xFF060A12),
      body: Stack(
        fit: StackFit.expand,
        children: [
          ModelViewer(
            backgroundColor: const Color(0xFF0A1422),
            id: 'car',
            src: 'lib/assets/roii.glb',
            alt: 'ROii vehicle',
            interpolationDecay: 200,
            disablePan: true, disableTap: true, disableZoom: false,
            cameraOrbit: '45deg 65deg 100%',
            cameraTarget: 'auto 8m auto',
            autoRotate: false,
            relatedJs: modelViewerScript,
            onWebViewCreated: (controller) {
              final service = ref.read(viewerServiceProvider);
              service.setController(controller);
              _waitForJs(service);
            },
          ),
          // status panels (top bar + left/right cards + sensor row)
          SafeArea(child: StatusOverlay(s: s, connected: connected)),
          // autonomy command buttons — top center, horizontal (no overlap)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 64),
                child: _CmdButtons(
                  enabled: connected,
                  cmdResult: s.cmdResult,
                  trajPoints: s.trajPoints,
                  onCmd: (c) => _send({'cmd': c}),
                ),
              ),
            ),
          ),
          // manual driving — full-width bottom: left steer joystick + right pedals
          Positioned(
            left: 0, right: 0, bottom: 16,
            child: SafeArea(
              top: false,
              child: DriveControls(
                onChanged: (v, steer) => _send({'cmd': 'teleop', 'v': v, 'steer': steer}),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact vertical autonomy command buttons (DRIVE / STOP / CLEAR).
class _CmdButtons extends StatelessWidget {
  final bool enabled;
  final String cmdResult;
  final int trajPoints;
  final void Function(String) onCmd;
  const _CmdButtons(
      {required this.enabled, required this.cmdResult, required this.trajPoints, required this.onCmd});

  @override
  Widget build(BuildContext context) {
    Widget btn(String label, String cmd, Color c, IconData icon) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: ElevatedButton.icon(
            onPressed: enabled ? () => onCmd(cmd) : null,
            icon: Icon(icon, size: 17),
            label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.withValues(alpha: 0.9),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.only(right: 10),
            child: Text('AUTONOMY', style: TextStyle(color: Colors.white.withValues(alpha: 0.5),
                fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w600))),
        btn('DRIVE', 'drive', const Color(0xFF16A34A), Icons.navigation),
        btn('STOP', 'stop', const Color(0xFFDC2626), Icons.stop),
        btn('CLEAR', 'clear', const Color(0xFF475569), Icons.clear),
      ]),
      if (cmdResult.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: const Color(0xCC0B1220), borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24)),
          child: Text('$cmdResult · traj $trajPoints pts',
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ),
    ]);
  }
}
