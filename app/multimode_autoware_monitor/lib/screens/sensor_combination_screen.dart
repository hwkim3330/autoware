import 'package:flutter/material.dart';

import '../services/monitoring_service.dart';
import '../widgets/sensor_combination_matrix.dart';
import '../widgets/summary_card.dart';
import 'screen_header.dart';

class SensorCombinationScreen extends StatelessWidget {
  final MonitoringService service;
  const SensorCombinationScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'Sensor Combination',
      builder: (context, data) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'SENSOR COMBINATION MATRIX',
              child: SensorCombinationMatrix(set: data.sensors),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'LEGEND',
              child: Wrap(
                spacing: 18,
                runSpacing: 8,
                children: const [
                  _Legend('ABSOLUTE_LOCALIZATION', 'LiDAR / GNSS / Camera'),
                  _Legend('RELATIVE_LOCALIZATION', 'IMU / Odometry'),
                  _Legend('PERCEPTION', 'object / lane detection'),
                  _Legend('SUPPORT', 'auxiliary'),
                  _Legend('UNUSED', 'not selected'),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  final String role;
  final String desc;
  const _Legend(this.role, this.desc);
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: KvRow(role, desc),
    );
  }
}
