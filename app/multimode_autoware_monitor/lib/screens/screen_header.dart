import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/enums.dart';
import '../models/monitoring_data.dart';
import '../services/monitoring_service.dart';
import '../theme/app_theme.dart';
import '../widgets/status_badge.dart';

/// Shared scaffold used by every screen: a top status bar (source, connection,
/// scenario, last update + STALE banner) plus a StreamBuilder body. Keeps all
/// screens DRY and consistent. (Helper beyond the base file list.)
class MonitorBody extends StatelessWidget {
  final MonitoringService service;
  final Widget Function(BuildContext, MonitoringData) builder;
  final String? titleOverride;

  const MonitorBody({
    super.key,
    required this.service,
    required this.builder,
    this.titleOverride,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(service: service, titleOverride: titleOverride),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: StreamBuilder<MonitoringData>(
            stream: service.dataStream,
            initialData: service.latest,
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) {
                return const Center(
                  child: Text('Waiting for data…',
                      style: TextStyle(color: AppTheme.textMuted)),
                );
              }
              return builder(context, data);
            },
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  final MonitoringService service;
  final String? titleOverride;
  const _TopBar({required this.service, this.titleOverride});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionInfo>(
      stream: service.connectionStream,
      initialData: service.connection,
      builder: (context, csnap) {
        final conn = csnap.data ?? service.connection;
        final stale = conn.status == ConnectionStatus.stale;
        return StreamBuilder<MonitoringData>(
          stream: service.dataStream,
          initialData: service.latest,
          builder: (context, dsnap) {
            final d = dsnap.data;
            return Container(
              color: AppTheme.surface,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Text(
                    titleOverride ?? AppConfig.appName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 14),
                  StatusBadge(
                    text: d?.source ?? connectionModeLabel(conn.mode),
                    color: _sourceColor(conn),
                  ),
                  const SizedBox(width: 8),
                  StatusBadge(
                    text: _connLabel(conn.status),
                    color: _connColor(conn.status),
                  ),
                  if (d != null) ...[
                    const SizedBox(width: 14),
                    Flexible(
                      child: Text(
                        '${d.scenario.name}  ·  ${d.scenario.environment}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 13),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (stale)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: StatusBadge(
                          text: 'STALE DATA',
                          color: StatusColors.amber,
                          filled: true),
                    ),
                  Text(
                    _lastUpdate(conn.lastReceived),
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static String _connLabel(ConnectionStatus s) {
    switch (s) {
      case ConnectionStatus.connected:
        return 'CONNECTED';
      case ConnectionStatus.connecting:
        return 'CONNECTING';
      case ConnectionStatus.disconnected:
        return 'DISCONNECTED';
      case ConnectionStatus.stale:
        return 'STALE';
    }
  }

  static Color _connColor(ConnectionStatus s) {
    switch (s) {
      case ConnectionStatus.connected:
        return StatusColors.green;
      case ConnectionStatus.connecting:
        return StatusColors.blue;
      case ConnectionStatus.disconnected:
        return StatusColors.red;
      case ConnectionStatus.stale:
        return StatusColors.amber;
    }
  }

  static Color _sourceColor(ConnectionInfo c) {
    switch (c.mode) {
      case ConnectionMode.demo:
        return StatusColors.blue;
      case ConnectionMode.wifi:
        return StatusColors.green;
      case ConnectionMode.usbAdb:
        return StatusColors.amber;
      case ConnectionMode.customNetwork:
        return StatusColors.green;
    }
  }

  static String _lastUpdate(DateTime? t) {
    if (t == null) return 'last update: —';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return 'last update: $h:$m:$s';
  }
}
