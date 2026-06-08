import '../models/enums.dart';

/// Static app-wide defaults. Connection settings are mutable at runtime
/// from the Settings screen; these are the initial values.
class AppConfig {
  static const appName = 'Multi-Mode Autoware Monitor';

  // Default data source on first launch.
  static const ConnectionMode defaultMode = ConnectionMode.demo;

  // Default WebSocket endpoints.
  static const String wifiExampleUrl = 'ws://192.168.0.10:8765/ws';
  static const String usbAdbUrl = 'ws://127.0.0.1:8765/ws';
  static const String defaultCustomUrl = 'ws://192.168.0.10:8765/ws';

  // WebSocket server defaults (also used by the Python mock server).
  static const int wsPort = 8765;
  static const String wsPath = '/ws';

  // If no frame arrives within this window, mark data as STALE.
  static const Duration staleAfter = Duration(seconds: 4);

  // Demo scenario tick interval.
  static const Duration demoTick = Duration(seconds: 3);

  // Reconnect backoff for WebSocket mode.
  static const Duration reconnectDelay = Duration(seconds: 3);

  static String urlForMode(ConnectionMode mode, String customUrl) {
    switch (mode) {
      case ConnectionMode.usbAdb:
        return usbAdbUrl;
      case ConnectionMode.wifi:
      case ConnectionMode.customNetwork:
        return customUrl;
      case ConnectionMode.demo:
        return '(internal mock)';
    }
  }
}
