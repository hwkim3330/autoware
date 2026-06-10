import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/autoware_state.dart';
import '../services/ws_monitor_service.dart';

/// Gateway URL. USB (adb reverse tcp:8765) by default; override for Wi-Fi.
final gatewayUrlProvider = StateProvider<String>((ref) => 'ws://127.0.0.1:8765/ws');

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
