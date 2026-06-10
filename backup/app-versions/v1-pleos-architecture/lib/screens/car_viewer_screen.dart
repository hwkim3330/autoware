import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import '../core/js_scripts.dart';
import '../models/fault_data.dart';
import '../providers/viewer_service_provider.dart';
import '../providers/fault_provider.dart';
import 'widgets/speed_widget.dart';
import 'widgets/control_bar.dart';
import 'widgets/fault_bottom_sheet.dart';
import 'widgets/legend_card.dart';

class CarViewerScreen extends ConsumerStatefulWidget {
  const CarViewerScreen({super.key});

  @override
  ConsumerState<CarViewerScreen> createState() => _CarViewerScreenState();
}

class _CarViewerScreenState extends ConsumerState<CarViewerScreen> {
  bool showHotspot = false;
  bool _isFaultSheetVisible = false;

  @override
  void initState() {
    super.initState();
    // Initialize fault stream immediately
    // This ensures the provider is created and listening for native events
    Future.microtask(() {
      ref.read(faultProvider);
    });
    // Start polling for error hotspot clicks
    Future.delayed(const Duration(seconds: 2), _startErrorHotspotPolling);
  }

  void _startErrorHotspotPolling() {
    if (!mounted) return;
    _checkErrorHotspotClicked();
    Future.delayed(
      const Duration(milliseconds: 500),
      _startErrorHotspotPolling,
    );
  }

  Future<void> _checkErrorHotspotClicked() async {
    final service = ref.read(viewerServiceProvider);
    final targetId = await service.checkErrorHotspotClicked();

    if (targetId != null && mounted) {
      final faults = ref
          .read(faultProvider.notifier)
          .getFaultsByTarget(targetId);
      if (faults.isNotEmpty) {
        _showFaultBottomSheet(faults);
      }
    }
  }

  void _showFaultBottomSheet(List<FaultData> faults) {
    setState(() => _isFaultSheetVisible = true);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      isScrollControlled: true,
      constraints: const BoxConstraints(
        minWidth: double.infinity,
        maxWidth: double.infinity,
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: FaultBottomSheet(faults: faults),
      ),
    ).then((_) {
      if (!mounted) return;
      setState(() => _isFaultSheetVisible = false);
      // Reset camera orbit when bottom sheet is dismissed
      ref.read(viewerServiceProvider).resetCameraOrbit();
    });
  }

  void _toggleHotspot() {
    setState(() {
      showHotspot = !showHotspot;
    });
    ref.read(viewerServiceProvider).toggleHotspots(showHotspot);
  }

  void _toggleMaterial() {
    ref.read(viewerServiceProvider).toggleMaterials();
  }

  void _switchOrbit() {
    ref.read(viewerServiceProvider).switchOrbit();
  }

  void _simulateFault() {
    ref.read(faultProvider.notifier).simulateFault();
  }

  Future<void> _waitForJsAndInitialize(service) async {
    // Poll until JS is ready
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;

      final isReady = await service.isJsReady();
      if (isReady) {
        await service.initializeLabelHotspots();
        return;
      }
    }
    // Fallback: try anyway after timeout
    await service.initializeLabelHotspots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ModelViewer(
                  backgroundColor: Colors.white,
                  id: 'car',
                  src: 'lib/assets/roii.glb',
                  alt: '3d model of a car',
                  interpolationDecay: 200,
                  disablePan: true,
                  disableTap: true,
                  disableZoom: false,
                  cameraOrbit: '45deg 65deg 100%',
                  cameraTarget: 'auto 8m auto',
                  relatedJs: modelViewerScript,
                  onWebViewCreated: (controller) {
                    final service = ref.read(viewerServiceProvider);
                    service.setController(controller);
                    // Wait for JS to be ready, then initialize label hotspots
                    _waitForJsAndInitialize(service);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SpeedWidget(),
                      AnimatedOpacity(
                        opacity: _isFaultSheetVisible ? 0 : 0.8,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                        child: const LegendCard(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Spacer(),
                      ControlBar(
                        showHotspot: showHotspot,
                        onToggleHotspot: _toggleHotspot,
                        onToggleMaterial: _toggleMaterial,
                        onSwitchOrbit: _switchOrbit,
                        onSimulateFault: _simulateFault,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
