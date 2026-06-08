import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../services/monitoring_service.dart';
import '../theme/app_theme.dart';
import '../widgets/localization_mode_card.dart';
import '../widgets/sensor_combination_matrix.dart';
import '../widgets/status_badge.dart';
import '../widgets/summary_card.dart';
import '../widgets/vehicle_visualizer.dart';
import 'dashboard_screen.dart' show safetyLabel;
import 'screen_header.dart';

/// Tesla-autopilot-style vehicle view: the ROii car with its live sensor suite,
/// the active localization mode overlaid, and the sensor matrix beside it.
class VehicleScreen extends StatelessWidget {
  final MonitoringService service;
  const VehicleScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'Vehicle',
      builder: (context, data) {
        final loc = data.localization;
        final safety = StatusColors.safety(data.metrics.safetyState);
        final viz = Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const RadialGradient(
                  center: Alignment.center,
                  radius: 0.9,
                  colors: [Color(0xFF131A24), Color(0xFF0D1117)],
                ),
                border: Border.all(color: AppTheme.border),
              ),
              padding: const EdgeInsets.all(8),
              child: VehicleVisualizer(sensors: data.sensors, localization: loc),
            ),
            Positioned(
              left: 16,
              top: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(localizationModeLabel(loc.mode),
                      style: TextStyle(
                          color: loc.mode == LocalizationMode.unavailable
                              ? StatusColors.red
                              : AppTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  StatusBadge(text: pipelineLabel(loc.pipelineType), color: StatusColors.pipeline(loc.pipelineType)),
                ],
              ),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: StatusBadge(
                  text: safetyLabel(data.metrics.safetyState),
                  color: safety,
                  filled: true),
            ),
          ],
        );

        final side = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LocalizationModeCard(loc: loc),
            const SizedBox(height: 14),
            SectionCard(
              title: 'SENSOR SUITE',
              child: SensorCombinationMatrix(set: data.sensors, compact: true),
            ),
            const SizedBox(height: 14),
            _legend(),
          ],
        );

        return LayoutBuilder(builder: (context, c) {
          if (c.maxWidth < 820) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              SizedBox(height: 360, child: viz),
              const SizedBox(height: 14),
              side,
            ]);
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: viz),
                const SizedBox(width: 16),
                Expanded(
                    flex: 4,
                    child: SingleChildScrollView(child: side)),
              ],
            ),
          );
        });
      },
    );
  }

  Widget _legend() => SectionCard(
        title: 'LEGEND',
        child: Wrap(spacing: 16, runSpacing: 8, children: [
          _chip(StatusColors.blue, 'LiDAR'),
          _chip(StatusColors.green, 'Camera'),
          _chip(StatusColors.amber, 'Radar'),
          _chip(StatusColors.green, 'NORMAL'),
          _chip(StatusColors.amber, 'DEGRADED'),
          _chip(StatusColors.red, 'FAULT'),
          _chip(StatusColors.gray, 'STANDBY/UNUSED'),
        ]),
      );

  Widget _chip(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Dot(c),
        const SizedBox(width: 6),
        Text(t, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
      ]);
}
