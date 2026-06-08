import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/sensor_state.dart';
import '../theme/app_theme.dart';
import 'status_badge.dart';

String sensorStatusLabel(SensorStatus s) => s.name.toUpperCase();

/// Matrix: rows = LiDAR/GNSS/Camera/IMU/Odometry,
/// columns = Status / Used / Role / Reason.
class SensorCombinationMatrix extends StatelessWidget {
  final SensorSet set;
  final bool compact;
  const SensorCombinationMatrix({super.key, required this.set, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final rows = set.ordered;
    return Column(
      children: [
        _header(),
        const Divider(height: 1, color: AppTheme.border),
        ...rows.map(_row),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No sensor data', style: TextStyle(color: AppTheme.textMuted)),
          ),
      ],
    );
  }

  Widget _header() {
    TextStyle h = AppTheme.labelStyle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('SENSOR', style: h)),
          Expanded(flex: 3, child: Text('STATUS', style: h)),
          Expanded(flex: 2, child: Text('USED', style: h)),
          Expanded(flex: 4, child: Text('ROLE', style: h)),
          if (!compact) Expanded(flex: 5, child: Text('REASON', style: h)),
        ],
      ),
    );
  }

  Widget _row(SensorState s) {
    final c = StatusColors.sensor(s.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Row(children: [
              Dot(c),
              const SizedBox(width: 8),
              Text(s.displayName,
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
            ]),
          ),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerLeft,
              child: StatusBadge(text: sensorStatusLabel(s.status), color: c, fontSize: 11),
            ),
          ),
          Expanded(
            flex: 2,
            child: Icon(
              s.used ? Icons.check_circle : Icons.remove_circle_outline,
              color: s.used ? StatusColors.green : AppTheme.textMuted,
              size: 18,
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(roleLabel(s.role),
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ),
          if (!compact)
            Expanded(
              flex: 5,
              child: Text(s.reason.isEmpty ? '—' : s.reason,
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
