import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../config/mode_catalog.dart';
import '../config/roii_vehicle_topology.dart';
import '../models/enums.dart';
import '../services/mock_monitoring_service.dart';
import '../services/monitoring_service.dart';
import '../theme/app_theme.dart';
import '../widgets/status_badge.dart';
import '../widgets/summary_card.dart';

class SettingsScreen extends StatefulWidget {
  final MonitoringService service;
  final ConnectionMode mode;
  final String customUrl;
  final Future<void> Function(ConnectionMode, String) onApply;
  final VoidCallback onReloadConfigs;

  const SettingsScreen({
    super.key,
    required this.service,
    required this.mode,
    required this.customUrl,
    required this.onApply,
    required this.onReloadConfigs,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ConnectionMode _mode = widget.mode;
  late final TextEditingController _url =
      TextEditingController(text: widget.customUrl);

  String _info = '';

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _onModeChanged(ConnectionMode? m) {
    if (m == null) return;
    setState(() {
      _mode = m;
      if (m == ConnectionMode.usbAdb) _url.text = AppConfig.usbAdbUrl;
      if (m == ConnectionMode.wifi && _url.text.isEmpty) {
        _url.text = AppConfig.wifiExampleUrl;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.service.connection;
    final urlEditable =
        _mode == ConnectionMode.wifi || _mode == ConnectionMode.customNetwork;
    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: const Text('Settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                title: 'DATA SOURCE',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<ConnectionMode>(
                      initialValue: _mode,
                      dropdownColor: AppTheme.surfaceAlt,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: ConnectionMode.demo, child: Text('DEMO')),
                        DropdownMenuItem(
                            value: ConnectionMode.wifi, child: Text('WIFI')),
                        DropdownMenuItem(
                            value: ConnectionMode.usbAdb,
                            child: Text('USB_ADB')),
                        DropdownMenuItem(
                            value: ConnectionMode.customNetwork,
                            child: Text('CUSTOM_NETWORK')),
                      ],
                      onChanged: _onModeChanged,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _url,
                      enabled: urlEditable,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: 'WebSocket URL',
                        helperText: _mode == ConnectionMode.usbAdb
                            ? 'USB ADB fixed: ${AppConfig.usbAdbUrl} '
                                '(run: adb reverse tcp:8765 tcp:8765)'
                            : _mode == ConnectionMode.demo
                                ? 'Demo uses in-app mock data (no URL needed)'
                                : 'e.g. ${AppConfig.wifiExampleUrl}',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      FilledButton.icon(
                        onPressed: () async {
                          await widget.onApply(_mode, _url.text.trim());
                          setState(() => _info =
                              'Connecting to ${AppConfig.urlForMode(_mode, _url.text.trim())}');
                        },
                        icon: const Icon(Icons.link),
                        label: const Text('Connect'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await widget.onApply(ConnectionMode.demo, _url.text.trim());
                          setState(() {
                            _mode = ConnectionMode.demo;
                            _info = 'Disconnected — back to DEMO';
                          });
                        },
                        icon: const Icon(Icons.link_off),
                        label: const Text('Disconnect (→ DEMO)'),
                      ),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SectionCard(
                title: 'CONNECTION STATUS',
                trailing: StatusBadge(
                  text: conn.status.name.toUpperCase(),
                  color: conn.status == ConnectionStatus.connected
                      ? StatusColors.green
                      : conn.status == ConnectionStatus.stale
                          ? StatusColors.amber
                          : StatusColors.gray,
                ),
                child: Column(children: [
                  KvRow('Active mode', connectionModeLabel(conn.mode)),
                  KvRow('URL', conn.url),
                  KvRow('Last received',
                      conn.lastReceived?.toLocal().toString() ?? '—'),
                  if (conn.lastError != null)
                    KvRow('Last error', conn.lastError!,
                        valueColor: StatusColors.red),
                  if (_info.isNotEmpty)
                    KvRow('Info', _info, valueColor: StatusColors.blue),
                ]),
              ),
              const SizedBox(height: 14),
              SectionCard(
                title: 'MAINTENANCE',
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        final s = widget.service;
                        if (s is MockMonitoringService) s.resetScenario();
                        setState(() => _info = 'Demo scenario reset');
                      },
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Demo Scenario Reset'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await ModeCatalog.load(reload: true);
                        widget.onReloadConfigs();
                        setState(() => _info = 'Mode catalog reloaded');
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Mode Catalog Reload'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await RoiiTopology.load(reload: true);
                        widget.onReloadConfigs();
                        setState(() => _info = 'ROii topology reloaded');
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('ROii Topology Reload'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const SectionCard(
                title: 'HELP',
                child: Text(
                  'Wi-Fi: same network as the PC, enter ws://<PC-IP>:8765/ws.\n'
                  'USB ADB: run "adb reverse tcp:8765 tcp:8765" on the PC, '
                  'then use ws://127.0.0.1:8765/ws.\n'
                  'On any connection failure the app keeps running on DEMO data.',
                  style: TextStyle(color: AppTheme.textMuted, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
