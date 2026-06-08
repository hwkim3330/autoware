import 'package:flutter/material.dart';
import '../models/autoware_state.dart';
import '../models/enums.dart';
import '../theme/app_theme.dart';
import 'status_badge.dart';

String moduleStatusLabel(ModuleStatus s) => s.name.toUpperCase();

class AutowareModuleTile extends StatelessWidget {
  final String moduleKey;
  final ModuleStatus status;
  const AutowareModuleTile({super.key, required this.moduleKey, required this.status});

  @override
  Widget build(BuildContext context) {
    final c = StatusColors.module(status);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Dot(c),
            const SizedBox(width: 8),
            Expanded(
              child: Text(AutowareState.moduleLabel(moduleKey),
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ]),
          const SizedBox(height: 10),
          StatusBadge(text: moduleStatusLabel(status), color: c, fontSize: 11),
        ],
      ),
    );
  }
}
