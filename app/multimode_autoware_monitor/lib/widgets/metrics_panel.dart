import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/enums.dart';

/// Horizontal bar gauge (no chart library).
class MetricBar extends StatelessWidget {
  final String label;
  final double value; // 0..100 typically
  final double max;
  final String display;
  final Color? color;
  const MetricBar({
    super.key,
    required this.label,
    required this.value,
    required this.display,
    this.max = 100,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final frac = (value / max).clamp(0.0, 1.0);
    final c = color ??
        (frac > 0.85
            ? StatusColors.red
            : frac > 0.65
                ? StatusColors.amber
                : StatusColors.green);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12))),
            Text(display,
                style: TextStyle(
                    color: c, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor: AppTheme.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(c),
            ),
          ),
        ],
      ),
    );
  }
}

/// Simple metric value tile for non-percentage metrics.
class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const MetricTile({super.key, required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppTheme.labelStyle),
        const SizedBox(height: 8),
        Text(value,
            style: TextStyle(
                color: color ?? AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800)),
      ]),
    );
  }
}
