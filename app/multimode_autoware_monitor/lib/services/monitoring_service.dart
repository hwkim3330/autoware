import 'dart:async';
import '../models/enums.dart';
import '../models/monitoring_data.dart';

/// Snapshot of the live connection, surfaced to the UI.
class ConnectionInfo {
  final ConnectionMode mode;
  final ConnectionStatus status;
  final String url;
  final DateTime? lastReceived;
  final String? lastError;

  const ConnectionInfo({
    required this.mode,
    required this.status,
    required this.url,
    this.lastReceived,
    this.lastError,
  });

  ConnectionInfo copyWith({
    ConnectionMode? mode,
    ConnectionStatus? status,
    String? url,
    DateTime? lastReceived,
    String? lastError,
  }) =>
      ConnectionInfo(
        mode: mode ?? this.mode,
        status: status ?? this.status,
        url: url ?? this.url,
        lastReceived: lastReceived ?? this.lastReceived,
        lastError: lastError,
      );
}

/// Common interface for both the mock and the live WebSocket source.
abstract class MonitoringService {
  Stream<MonitoringData> get dataStream;
  Stream<ConnectionInfo> get connectionStream;
  ConnectionInfo get connection;
  MonitoringData? get latest;

  Future<void> start();
  Future<void> stop();
  void dispose();
}
