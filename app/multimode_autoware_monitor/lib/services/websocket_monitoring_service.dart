import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../config/app_config.dart';
import '../models/enums.dart';
import '../models/monitoring_data.dart';
import 'mock_monitoring_service.dart';
import 'monitoring_service.dart';

/// Live WebSocket source. Robust by design:
///  - never throws to the UI; connection problems become ConnectionStatus
///  - if a connection cannot be established or drops, it auto-falls back to
///    the in-app demo generator so the dashboard keeps moving
///  - if frames stop arriving for [AppConfig.staleAfter], status -> stale
class WebSocketMonitoringService implements MonitoringService {
  final String url;
  final ConnectionMode mode;
  final bool fallbackToDemo;

  WebSocketMonitoringService({
    required this.url,
    required this.mode,
    this.fallbackToDemo = true,
  });

  final _data = StreamController<MonitoringData>.broadcast();
  final _conn = StreamController<ConnectionInfo>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _staleTimer;
  Timer? _reconnectTimer;
  bool _stopped = false;
  bool _fallbackActive = false;

  final MockMonitoringService _fallback = MockMonitoringService();
  StreamSubscription<MonitoringData>? _fallbackSub;

  MonitoringData? _latest;
  late ConnectionInfo _connection = ConnectionInfo(
    mode: mode,
    status: ConnectionStatus.disconnected,
    url: url,
  );

  @override
  Stream<MonitoringData> get dataStream => _data.stream;
  @override
  Stream<ConnectionInfo> get connectionStream => _conn.stream;
  @override
  ConnectionInfo get connection => _connection;
  @override
  MonitoringData? get latest => _latest;

  @override
  Future<void> start() async {
    _stopped = false;
    await _connect();
    _staleTimer?.cancel();
    _staleTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _checkStale());
  }

  Future<void> _connect() async {
    _setStatus(ConnectionStatus.connecting);
    try {
      final ch = WebSocketChannel.connect(Uri.parse(url));
      _channel = ch;
      // connect() is lazy; readiness confirmed on first frame.
      _sub = ch.stream.listen(
        _onMessage,
        onError: (e) => _onDisconnect('socket error: $e'),
        onDone: () => _onDisconnect('socket closed'),
        cancelOnError: true,
      );
    } catch (e) {
      _onDisconnect('connect failed: $e');
    }
  }

  void _onMessage(dynamic raw) {
    _stopFallback();
    try {
      final j = jsonDecode(raw is String ? raw : utf8.decode(raw)) as Map<String, dynamic>;
      final data = MonitoringData.fromJson(j, receivedAt: DateTime.now())
          .copyWith(source: connectionModeLabel(mode));
      _latest = data;
      if (!_data.isClosed) _data.add(data);
      _connection = _connection.copyWith(
        status: ConnectionStatus.connected,
        lastReceived: data.receivedAt,
        lastError: null,
      );
      _push();
    } catch (e) {
      // Malformed frame: keep the connection but note the error.
      _connection = _connection.copyWith(lastError: 'parse error: $e');
      _push();
    }
  }

  void _onDisconnect(String reason) {
    if (_stopped) return;
    _setStatus(ConnectionStatus.disconnected, error: reason);
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (fallbackToDemo) _startFallback();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(AppConfig.reconnectDelay, () {
      if (!_stopped) _connect();
    });
  }

  void _checkStale() {
    final last = _connection.lastReceived;
    if (_connection.status == ConnectionStatus.connected &&
        last != null &&
        DateTime.now().difference(last) > AppConfig.staleAfter) {
      _setStatus(ConnectionStatus.stale);
      if (fallbackToDemo) _startFallback();
    }
  }

  void _startFallback() {
    if (_fallbackActive) return;
    _fallbackActive = true;
    _fallbackSub = _fallback.dataStream.listen((d) {
      // Tag fallback frames as DEMO so the UI shows the real source.
      final tagged = d.copyWith(source: 'DEMO (fallback)');
      _latest = tagged;
      if (!_data.isClosed) _data.add(tagged);
    });
    _fallback.start();
  }

  void _stopFallback() {
    if (!_fallbackActive) return;
    _fallbackActive = false;
    _fallbackSub?.cancel();
    _fallbackSub = null;
    _fallback.stop();
  }

  void _setStatus(ConnectionStatus s, {String? error}) {
    _connection = _connection.copyWith(status: s, lastError: error);
    _push();
  }

  void _push() {
    if (!_conn.isClosed) _conn.add(_connection);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _staleTimer?.cancel();
    _stopFallback();
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
    _setStatus(ConnectionStatus.disconnected);
  }

  @override
  void dispose() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _staleTimer?.cancel();
    _fallbackSub?.cancel();
    _fallback.dispose();
    _sub?.cancel();
    _data.close();
    _conn.close();
  }
}
