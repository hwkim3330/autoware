import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/localization_state.dart';
import '../theme/app_theme.dart';
import 'status_badge.dart';
import 'summary_card.dart';

String localizationModeLabel(LocalizationMode m) {
  switch (m) {
    case LocalizationMode.lidarOnly:
      return 'LiDAR only';
    case LocalizationMode.gnssOnly:
      return 'GNSS only';
    case LocalizationMode.cameraOnly:
      return 'Camera only';
    case LocalizationMode.lidarGnss:
      return 'LiDAR + GNSS';
    case LocalizationMode.lidarCamera:
      return 'LiDAR + Camera';
    case LocalizationMode.gnssCamera:
      return 'GNSS + Camera';
    case LocalizationMode.lidarGnssCamera:
      return 'LiDAR + GNSS + Camera';
    case LocalizationMode.unavailable:
      return 'UNAVAILABLE';
    case LocalizationMode.unknown:
      return '-';
  }
}

String pipelineLabel(PipelineType p) {
  switch (p) {
    case PipelineType.single:
      return 'SINGLE';
    case PipelineType.dual:
      return 'DUAL';
    case PipelineType.triple:
      return 'TRIPLE';
    case PipelineType.unavailable:
      return 'UNAVAILABLE';
    case PipelineType.unknown:
      return '-';
  }
}

class LocalizationModeCard extends StatelessWidget {
  final LocalizationState loc;
  const LocalizationModeCard({super.key, required this.loc});

  @override
  Widget build(BuildContext context) {
    final pColor = StatusColors.pipeline(loc.pipelineType);
    return SectionCard(
      title: 'LOCALIZATION MODE',
      trailing: StatusBadge(text: pipelineLabel(loc.pipelineType), color: pColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            localizationModeLabel(loc.mode),
            style: TextStyle(
              color: loc.mode == LocalizationMode.unavailable
                  ? StatusColors.red
                  : AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          KvRow('Absolute sensors',
              loc.absoluteSensors.isEmpty ? '-' : loc.absoluteSensors.join(', ')),
          KvRow('Relative sensors',
              loc.relativeSensors.isEmpty ? '-' : loc.relativeSensors.join(', ')),
          KvRow('Fusion method', loc.fusionMethod),
          KvRow('Confidence', '${(loc.confidence * 100).toStringAsFixed(0)} %',
              valueColor: loc.confidence >= 0.9
                  ? StatusColors.green
                  : loc.confidence >= 0.7
                      ? StatusColors.amber
                      : StatusColors.red),
          KvRow('Localization latency', '${loc.latencyMs.toStringAsFixed(1)} ms'),
        ],
      ),
    );
  }
}
