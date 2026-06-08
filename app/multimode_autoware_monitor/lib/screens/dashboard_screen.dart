import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/monitoring_data.dart';
import '../services/monitoring_service.dart';
import '../theme/app_theme.dart';
import '../widgets/event_timeline.dart';
import '../widgets/localization_mode_card.dart';
import '../widgets/summary_card.dart';
import '../widgets/vehicle_visualizer.dart';
import 'screen_header.dart';

String safetyLabel(SafetyState s) => s.name
    .replaceAllMapped(RegExp('([A-Z])'), (m) => ' ${m[1]}')
    .trim()
    .toUpperCase();

class DashboardScreen extends StatelessWidget {
  final MonitoringService service;
  const DashboardScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      builder: (context, data) {
        final loc = data.localization;
        final m = data.metrics;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ---- vehicle visualization + hero values (wide) ----
            LayoutBuilder(builder: (context, c) {
              if (c.maxWidth >= 760) {
                return SizedBox(
                  height: 300,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 230,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const RadialGradient(radius: 0.9, colors: [
                            Color(0xFF131A24),
                            Color(0xFF0D1117),
                          ]),
                          border: Border.all(color: AppTheme.border),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: VehicleVisualizer(
                            sensors: data.sensors, localization: loc),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: _heroGrid(data, 2)),
                    ],
                  ),
                );
              }
              return Column(children: [
                SizedBox(
                  height: 280,
                  child: VehicleVisualizer(
                      sensors: data.sensors, localization: loc),
                ),
                const SizedBox(height: 14),
                _heroGrid(data, 2),
              ]);
            }),
            const SizedBox(height: 14),
            // ---- transition reason + localization ----
            _twoCol(
              context,
              SectionCard(
                title: 'STATE & TRANSITION',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KvRow('6-State ID', data.stateMachine.stateId),
                    KvRow('State name', data.stateMachine.displayName),
                    KvRow('Previous state', data.stateMachine.previousStateId),
                    KvRow('Transition', data.stateMachine.transitionStatus),
                    const SizedBox(height: 4),
                    Text('Transition reason',
                        style: AppTheme.labelStyle),
                    const SizedBox(height: 4),
                    Text(
                      data.stateMachine.transitionReason.isEmpty
                          ? '—'
                          : data.stateMachine.transitionReason,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 13),
                    ),
                  ],
                ),
              ),
              LocalizationModeCard(loc: loc),
            ),
            const SizedBox(height: 14),
            // ---- key metrics + events ----
            _twoCol(
              context,
              SectionCard(
                title: 'KEY PERFORMANCE',
                child: Column(children: [
                  KvRow('End-to-end latency',
                      '${m.endToEndLatencyMs.toStringAsFixed(0)} ms'),
                  KvRow('Localization latency',
                      '${m.localizationLatencyMs.toStringAsFixed(1)} ms'),
                  KvRow('Mode transition time',
                      '${m.modeTransitionTimeMs.toStringAsFixed(0)} ms'),
                  KvRow('Trajectory error',
                      '${m.trajectoryError.toStringAsFixed(3)} m'),
                  KvRow('Resource saving',
                      '${m.resourceSavingPercent.toStringAsFixed(1)} %',
                      valueColor: StatusColors.green),
                ]),
              ),
              SectionCard(
                title: 'RECENT EVENTS',
                child: EventTimelineList(events: data.events, max: 6),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _heroGrid(MonitoringData data, int cols) {
    final loc = data.localization;
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.3,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      children: [
        HeroValueCard(
          label: 'CURRENT LOCALIZATION MODE',
          value: localizationModeLabel(loc.mode),
          color: loc.mode == LocalizationMode.unavailable
              ? StatusColors.red
              : StatusColors.green,
          subtitle: 'Pipeline: ${pipelineLabel(loc.pipelineType)}',
        ),
        HeroValueCard(
          label: 'SENSOR COMBINATION',
          value: loc.absoluteSensors.isEmpty
              ? 'NONE'
              : loc.absoluteSensors.join(' + '),
          color: StatusColors.blue,
          subtitle:
              'Relative: ${loc.relativeSensors.isEmpty ? '-' : loc.relativeSensors.join(', ')}',
        ),
        HeroValueCard(
          label: 'SELECTED AUTOWARE STACK',
          value: data.autoware.selectedStack,
          color: StatusColors.amber,
          subtitle: data.stateMachine.stateId,
        ),
        HeroValueCard(
          label: 'SAFETY STATE',
          value: safetyLabel(data.metrics.safetyState),
          color: StatusColors.safety(data.metrics.safetyState),
          subtitle: data.scenario.drivingArea,
        ),
      ],
    );
  }

  Widget _twoCol(BuildContext context, Widget a, Widget b) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 760) {
        return Column(children: [a, const SizedBox(height: 14), b]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: a),
          const SizedBox(width: 14),
          Expanded(child: b),
        ],
      );
    });
  }
}
