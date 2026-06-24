import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/autoware_state.dart';
import '../services/ws_monitor_service.dart';

/// Gateway URL. Default differs by flavor: the read-only HMI app (APP_MODE=hmi)
/// points at the HMI gateway (8766 in sim), the command app at the full-control
/// gateway (8765). Override in-app via settings (Wi-Fi: `ws://<PC-IP>:port/ws`).
const _appMode = String.fromEnvironment('APP_MODE', defaultValue: 'command');
final gatewayUrlProvider = StateProvider<String>((ref) =>
    _appMode == 'hmi' ? 'ws://127.0.0.1:8766/ws' : 'ws://127.0.0.1:8765/ws');

final wsMonitorServiceProvider = Provider<WsMonitorService>((ref) {
  final url = ref.watch(gatewayUrlProvider);
  final svc = WsMonitorService(url: url);
  svc.start();
  ref.onDispose(svc.dispose);
  return svc;
});

/// Live Autoware state stream. Starts disconnected until the first frame.
final autowareStateProvider = StreamProvider<AutowareState>((ref) {
  final svc = ref.watch(wsMonitorServiceProvider);
  return svc.stream;
});

/// One-time lane map (sent by the gateway on connect) for the 2D map.
final lanesProvider = StreamProvider<List<List<double>>>((ref) {
  final svc = ref.watch(wsMonitorServiceProvider);
  return svc.lanesStream;
});

/// Per-lanelet road polylines (continuous Tesla-style road rendering).
final lanePolysProvider = StreamProvider<List<List<List<double>>>>((ref) {
  final svc = ref.watch(wsMonitorServiceProvider);
  return svc.polysStream;
});

/// Front-camera JPEG frames for the dashboard camera popup.
final cameraProvider = StreamProvider<Uint8List>((ref) {
  final svc = ref.watch(wsMonitorServiceProvider);
  return svc.cameraStream;
});
