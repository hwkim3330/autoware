import 'package:flutter/material.dart';

import '../models/roii_architecture_state.dart';
import '../services/monitoring_service.dart';
import '../widgets/roii_zone_panel.dart';
import '../widgets/summary_card.dart';
import 'screen_header.dart';

class RoiiArchitectureScreen extends StatelessWidget {
  final MonitoringService service;
  const RoiiArchitectureScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'ROii Architecture',
      builder: (context, data) {
        final r = data.roii;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'HPC / BACKBONE',
              child: BackbonePanel(
                hpcName: 'ACU_IT / HPC',
                hpc: r.hpc,
                primary: r.backbonePrimary,
                secondary: r.backboneSecondary,
                dataFlow: r.dataFlowStatus,
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'ZONE CONTROLLERS',
              child: LayoutBuilder(builder: (context, c) {
                final wide = c.maxWidth > 820;
                final panels = [
                  for (final z in RoiiArchitectureState.zoneOrder)
                    RoiiZonePanel(
                      zoneKey: z,
                      status: r.zones[z] ?? r.dataFlowStatus,
                      sensors: r.sensorMap[z] ?? const [],
                    ),
                ];
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < panels.length; i++) ...[
                        Expanded(child: panels[i]),
                        if (i != panels.length - 1) const SizedBox(width: 12),
                      ],
                    ],
                  );
                }
                return Column(
                  children: [
                    for (final p in panels) ...[p, const SizedBox(height: 12)],
                  ],
                );
              }),
            ),
          ],
        );
      },
    );
  }
}
