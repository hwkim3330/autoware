import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/localization_state.dart';
import '../theme/app_theme.dart';
import 'status_badge.dart';

/// Visualizes the Single / Dual / Triple localization pipeline as boxes and
/// arrows (no external chart library).
class PipelineView extends StatelessWidget {
  final LocalizationState loc;
  const PipelineView({super.key, required this.loc});

  @override
  Widget build(BuildContext context) {
    switch (loc.pipelineType) {
      case PipelineType.single:
        return _single();
      case PipelineType.dual:
        return _dual();
      case PipelineType.triple:
        return _triple();
      case PipelineType.unavailable:
      case PipelineType.unknown:
        return _unavailable();
    }
  }

  Widget _box(String title, String sub, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.7)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title,
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14)),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(sub,
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ),
        ]),
      );

  Widget get _arrow => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.arrow_forward, color: AppTheme.textMuted, size: 20),
      );

  Widget _fusion(String label) => _box(
        'FUSION',
        label,
        StatusColors.blue,
      );

  Widget _single() {
    final abs = loc.absoluteSensors.isNotEmpty ? loc.absoluteSensors.first : '—';
    final rel = loc.relativeSensors.isNotEmpty ? loc.relativeSensors.first : '—';
    return _wrap([
      _box(abs, 'absolute', StatusColors.green),
      _arrow,
      _box(rel, 'relative', StatusColors.amber),
      _arrow,
      _box('POSE', '${loc.latencyMs.toStringAsFixed(0)} ms', StatusColors.blue),
    ]);
  }

  Widget _dual() {
    final a = loc.absoluteSensors.isNotEmpty ? loc.absoluteSensors[0] : '—';
    final b = loc.absoluteSensors.length > 1 ? loc.absoluteSensors[1] : '—';
    return _wrap([
      Column(children: [
        _box('$a pipeline', 'w=${_w(a)}', StatusColors.green),
        const SizedBox(height: 8),
        _box('$b pipeline', 'w=${_w(b)}', StatusColors.green),
      ]),
      _arrow,
      _fusion(loc.fusionMethod),
      _arrow,
      _box('POSE', '${loc.latencyMs.toStringAsFixed(0)} ms', StatusColors.blue),
    ]);
  }

  Widget _triple() {
    return _wrap([
      Column(children: [
        _box('LiDAR pipeline', 'w=${_w('LiDAR')}', StatusColors.green),
        const SizedBox(height: 6),
        _box('GNSS pipeline', 'w=${_w('GNSS')}', StatusColors.green),
        const SizedBox(height: 6),
        _box('Camera pipeline', 'w=${_w('Camera')}', StatusColors.green),
      ]),
      _arrow,
      _fusion(loc.fusionMethod),
      _arrow,
      _box('POSE', '${loc.latencyMs.toStringAsFixed(0)} ms', StatusColors.blue),
    ]);
  }

  Widget _unavailable() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: StatusColors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: StatusColors.red),
        ),
        child: const Column(children: [
          Icon(Icons.report, color: StatusColors.red, size: 32),
          SizedBox(height: 8),
          Text('LOCALIZATION PIPELINE UNAVAILABLE',
              style: TextStyle(color: StatusColors.red, fontWeight: FontWeight.w800)),
          SizedBox(height: 4),
          Text('Safe stop required', style: TextStyle(color: AppTheme.textMuted)),
        ]),
      );

  String _w(String sensor) {
    switch (sensor.toLowerCase()) {
      case 'lidar':
        return loc.fusionLidar.toStringAsFixed(2);
      case 'gnss':
        return loc.fusionGnss.toStringAsFixed(2);
      case 'camera':
        return loc.fusionCamera.toStringAsFixed(2);
      default:
        return '—';
    }
  }

  Widget _wrap(List<Widget> children) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.center, children: children),
      );
}
