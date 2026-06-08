import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../services/monitoring_service.dart';
import '../widgets/metrics_panel.dart';
import '../widgets/summary_card.dart';
import 'dashboard_screen.dart' show safetyLabel;
import 'screen_header.dart';

class MetricsScreen extends StatelessWidget {
  final MonitoringService service;
  const MetricsScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'Metrics',
      builder: (context, data) {
        final m = data.metrics;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'RESOURCE USAGE',
              child: Column(children: [
                MetricBar(
                    label: 'CPU',
                    value: m.cpuUsagePercent,
                    display: '${m.cpuUsagePercent.toStringAsFixed(0)} %'),
                MetricBar(
                    label: 'GPU',
                    value: m.gpuUsagePercent,
                    display: '${m.gpuUsagePercent.toStringAsFixed(0)} %'),
                MetricBar(
                    label: 'Memory',
                    value: m.memoryUsagePercent,
                    display: '${m.memoryUsagePercent.toStringAsFixed(0)} %'),
              ]),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'LATENCY & TIMING',
              child: GridView.count(
                crossAxisCount:
                    MediaQuery.of(context).size.width > 1000 ? 3 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 2.2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                children: [
                  MetricTile(
                      label: 'END-TO-END LATENCY',
                      value: '${m.endToEndLatencyMs.toStringAsFixed(0)} ms'),
                  MetricTile(
                      label: 'LOCALIZATION LATENCY',
                      value: '${m.localizationLatencyMs.toStringAsFixed(1)} ms'),
                  MetricTile(
                      label: 'MODE TRANSITION',
                      value: '${m.modeTransitionTimeMs.toStringAsFixed(0)} ms'),
                  MetricTile(
                      label: 'ARCH RECONFIG',
                      value:
                          '${m.architectureReconfigurationTimeMs.toStringAsFixed(0)} ms'),
                  MetricTile(
                      label: 'TRAJECTORY ERROR',
                      value: '${m.trajectoryError.toStringAsFixed(3)} m'),
                  MetricTile(
                      label: 'RESOURCE SAVING',
                      value: '${m.resourceSavingPercent.toStringAsFixed(1)} %',
                      color: StatusColors.green),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'SAFETY',
              child: MetricTile(
                label: 'SAFETY STATE',
                value: safetyLabel(m.safetyState),
                color: StatusColors.safety(m.safetyState),
              ),
            ),
          ],
        );
      },
    );
  }
}
