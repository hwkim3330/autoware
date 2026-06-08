import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config/app_config.dart';
import 'models/enums.dart';
import 'services/mock_monitoring_service.dart';
import 'services/monitoring_service.dart';
import 'services/websocket_monitoring_service.dart';
import 'theme/app_theme.dart';

import 'screens/dashboard_screen.dart';
import 'screens/vehicle_screen.dart';
import 'screens/localization_screen.dart';
import 'screens/sensor_combination_screen.dart';
import 'screens/autoware_stack_screen.dart';
import 'screens/roii_architecture_screen.dart';
import 'screens/metrics_screen.dart';
import 'screens/event_timeline_screen.dart';
import 'screens/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MonitorApp());
}

class MonitorApp extends StatelessWidget {
  const MonitorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: const AppShell(),
    );
  }
}

/// Owns the active MonitoringService and lets the Settings screen reconfigure
/// the data source at runtime. No external state-management package.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  ConnectionMode _mode = AppConfig.defaultMode;
  String _customUrl = AppConfig.defaultCustomUrl;
  late MonitoringService _service;

  @override
  void initState() {
    super.initState();
    _service = MockMonitoringService();
    _service.start();
  }

  Future<void> applyConnection(ConnectionMode mode, String url) async {
    await _service.stop();
    _service.dispose();
    final next = (mode == ConnectionMode.demo)
        ? MockMonitoringService()
        : WebSocketMonitoringService(
            url: AppConfig.urlForMode(mode, url), mode: mode);
    setState(() {
      _mode = mode;
      _customUrl = url;
      _service = next;
    });
    await next.start();
  }

  void reloadConfigs() {
    // Force config caches to reload on next access by reopening screens.
    setState(() {});
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  static const _dests = [
    (Icons.dashboard, 'Dashboard'),
    (Icons.directions_car, 'Vehicle'),
    (Icons.my_location, 'Localization'),
    (Icons.sensors, 'Sensors'),
    (Icons.account_tree, 'Autoware'),
    (Icons.hub, 'ROii Arch'),
    (Icons.speed, 'Metrics'),
    (Icons.timeline, 'Events'),
    (Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      DashboardScreen(service: _service),
      VehicleScreen(service: _service),
      LocalizationScreen(service: _service),
      SensorCombinationScreen(service: _service),
      AutowareStackScreen(service: _service),
      RoiiArchitectureScreen(service: _service),
      MetricsScreen(service: _service),
      EventTimelineScreen(service: _service),
      SettingsScreen(
        service: _service,
        mode: _mode,
        customUrl: _customUrl,
        onApply: applyConnection,
        onReloadConfigs: reloadConfigs,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              minWidth: 76,
              destinations: [
                for (final d in _dests)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    label: Text(d.$2),
                  ),
              ],
            ),
            const VerticalDivider(width: 1, color: AppTheme.border),
            Expanded(child: screens[_index]),
          ],
        ),
      ),
    );
  }
}
