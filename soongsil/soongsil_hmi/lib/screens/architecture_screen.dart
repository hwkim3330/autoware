import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import '../core/js_scripts.dart';
import '../core/constants.dart';
import '../models/autoware_state.dart';
import '../providers/viewer_service_provider.dart';
import '../providers/monitor_provider.dart';
import 'widgets/status_overlay.dart';

/// ROii E/E architecture view: full-screen interactive 3D model (zones, TSN
/// switches, sensor suite) with the live Autoware status overlay and fault
/// highlighting. Opened from the dashboard dock — Tesla keeps the map as the
/// main screen; this is the "vehicle / architecture" app.
class ArchitectureScreen extends ConsumerStatefulWidget {
  const ArchitectureScreen({super.key});
  @override
  ConsumerState<ArchitectureScreen> createState() => _S();
}

class _S extends ConsumerState<ArchitectureScreen> {
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
          SafeArea(child: StatusOverlay(s: s, connected: connected)),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                  style: IconButton.styleFrom(backgroundColor: const Color(0xAA0B1220)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
