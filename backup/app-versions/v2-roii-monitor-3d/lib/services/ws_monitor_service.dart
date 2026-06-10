import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/autoware_state.dart';

/// Connects to the Autoware ROS gateway (ros/ros_ws_gateway.py) over WebSocket,
/// parses frames, and exposes a broadcast stream of [AutowareState].
/// Auto-reconnects; emits a disconnected state while down.
class WsMonitorService {
  /// USB (adb reverse) default. For Wi-Fi use ws://<host-ip>:8765/ws.
  final String url;
  WsMonitorService({this.url = 'ws://127.0.0.1:8765/ws'});

  final _controller = StreamController<AutowareState>.broadcast();
  Stream<AutowareState> get stream => _controller.stream;

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _retry;
  bool _connected = false;
  bool get connected => _connected;

  void start() => _connect();

  /// Send a command to the gateway, e.g. {"cmd": "drive"|"stop"|"clear"}.
  void send(Map<String, dynamic> msg) {
    try {
      _ch?.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('WsMonitor send failed: $e');
    }
  }

  void _connect() {
    try {
      _ch = WebSocketChannel.connect(Uri.parse(url));
      _sub = _ch!.stream.listen(
        (data) {
          _connected = true;
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            _controller.add(AutowareState.fromJson(json));
          } catch (e) {
            debugPrint('WsMonitor parse error: $e');
          }
        },
        onDone: _onDrop,
        onError: (e) {
          debugPrint('WsMonitor error: $e');
          _onDrop();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('WsMonitor connect failed: $e');
      _onDrop();
    }
  }

  void _onDrop() {
    if (_connected) {
      _connected = false;
      _controller.add(AutowareState.disconnected());
    } else {
      _controller.add(AutowareState.disconnected());
    }
    _sub?.cancel();
    _sub = null;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), _connect);
  }

  void dispose() {
    _retry?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _controller.close();
  }
}
