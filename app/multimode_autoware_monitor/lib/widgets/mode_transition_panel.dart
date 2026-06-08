import 'package:flutter/material.dart';
import '../models/state_machine_state.dart';
import '../theme/app_theme.dart';

/// Shows previous -> current state transition with the reason.
class ModeTransitionPanel extends StatelessWidget {
  final StateMachineState sm;
  final String? previousModeLabel;
  final String? currentModeLabel;
  const ModeTransitionPanel({
    super.key,
    required this.sm,
    this.previousModeLabel,
    this.currentModeLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(String id, String? mode, {bool current = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: current
                ? AppTheme.accent.withValues(alpha: 0.14)
                : AppTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: current ? AppTheme.accent : AppTheme.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(id,
                style: TextStyle(
                    color: current ? AppTheme.accent : AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
            if (mode != null)
              Text(mode,
                  style:
                      const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          ]),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Flexible(child: chip(sm.previousStateId, previousModeLabel)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.east, color: AppTheme.textMuted),
          ),
          Flexible(child: chip(sm.stateId, currentModeLabel, current: true)),
        ]),
        const SizedBox(height: 10),
        Text('Transition: ${sm.transitionStatus}',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        if (sm.transitionReason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Reason: ${sm.transitionReason}',
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 13)),
          ),
      ],
    );
  }
}
