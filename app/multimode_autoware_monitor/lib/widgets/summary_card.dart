import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Reusable titled card container.
class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final Color? borderColor;
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.card(borderColor: borderColor),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppTheme.labelStyle)),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// A big headline value (used on the dashboard for the 4 hero metrics).
class HeroValueCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final String? subtitle;
  const HeroValueCard({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.card(borderColor: color.withValues(alpha: 0.5)),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: AppTheme.labelStyle),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// Simple label : value row.
class KvRow extends StatelessWidget {
  final String k;
  final String v;
  final Color? valueColor;
  const KvRow(this.k, this.v, {super.key, this.valueColor});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(k,
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          ),
          Expanded(
            flex: 6,
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: valueColor ?? AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
