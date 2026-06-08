import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../services/monitoring_service.dart';
import '../widgets/localization_mode_card.dart';
import '../widgets/mode_transition_panel.dart';
import '../widgets/pipeline_view.dart';
import '../widgets/summary_card.dart';
import 'screen_header.dart';

class LocalizationScreen extends StatelessWidget {
  final MonitoringService service;
  const LocalizationScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'Localization Mode',
      builder: (context, data) {
        final loc = data.localization;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            LocalizationModeCard(loc: loc),
            const SizedBox(height: 14),
            SectionCard(
              title: 'PIPELINE STRUCTURE',
              child: PipelineView(loc: loc),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'FUSION WEIGHTS',
              child: Column(children: [
                KvRow('LiDAR', loc.fusionLidar.toStringAsFixed(2)),
                KvRow('GNSS', loc.fusionGnss.toStringAsFixed(2)),
                KvRow('Camera', loc.fusionCamera.toStringAsFixed(2)),
                KvRow('Method', loc.fusionMethod),
              ]),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'MODE TRANSITION',
              child: ModeTransitionPanel(
                sm: data.stateMachine,
                currentModeLabel: localizationModeLabel(loc.mode),
              ),
            ),
          ],
        );
      },
    );
  }
}
