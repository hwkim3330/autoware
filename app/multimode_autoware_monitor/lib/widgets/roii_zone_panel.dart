import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/roii_architecture_state.dart';
import '../theme/app_theme.dart';
import 'status_badge.dart';

String architectureStatusLabel(ArchitectureStatus s) => s.name.toUpperCase();

/// 2D card for a single ROii zone controller and its sensors.
class RoiiZonePanel extends StatelessWidget {
  final String zoneKey;
  final ArchitectureStatus status;
  final List<String> sensors;
  const RoiiZonePanel({
    super.key,
    required this.zoneKey,
    required this.status,
    required this.sensors,
  });

  @override
  Widget build(BuildContext context) {
    final c = StatusColors.architecture(status);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.developer_board, size: 16, color: AppTheme.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(RoiiArchitectureState.zoneLabel(zoneKey),
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13)),
            ),
            StatusBadge(text: architectureStatusLabel(status), color: c, fontSize: 10),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: sensors.map(_chip).toList(),
          ),
          if (sensors.isEmpty)
            const Text('no sensors',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _chip(String name) {
    Color c = AppTheme.textMuted;
    if (name.startsWith('LiDAR')) c = StatusColors.blue;
    if (name.startsWith('Cam')) c = StatusColors.green;
    if (name.startsWith('Radar')) c = StatusColors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(name, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

/// Backbone / HPC top bar.
class BackbonePanel extends StatelessWidget {
  final String hpcName;
  final ArchitectureStatus hpc;
  final ArchitectureStatus primary;
  final ArchitectureStatus secondary;
  final ArchitectureStatus dataFlow;
  const BackbonePanel({
    super.key,
    required this.hpcName,
    required this.hpc,
    required this.primary,
    required this.secondary,
    required this.dataFlow,
  });

  @override
  Widget build(BuildContext context) {
    Widget node(String label, ArchitectureStatus s, IconData ic) {
      final c = StatusColors.architecture(s);
      return Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withValues(alpha: 0.6)),
          ),
          child: Column(children: [
            Icon(ic, color: c, size: 18),
            const SizedBox(height: 4),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
            Text(architectureStatusLabel(s),
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
          ]),
        ),
      );
    }

    return Row(children: [
      node(hpcName, hpc, Icons.memory),
      node('10G Primary', primary, Icons.lan),
      node('10G Secondary', secondary, Icons.lan_outlined),
      node('Data Flow', dataFlow, Icons.swap_horiz),
    ]);
  }
}
