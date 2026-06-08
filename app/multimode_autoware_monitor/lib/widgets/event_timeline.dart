import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/event_log.dart';
import '../theme/app_theme.dart';

class EventTimelineList extends StatelessWidget {
  final List<EventLog> events;
  final int? max;
  final bool reverse;
  const EventTimelineList({
    super.key,
    required this.events,
    this.max,
    this.reverse = true,
  });

  @override
  Widget build(BuildContext context) {
    var list = List<EventLog>.from(events);
    if (reverse) list = list.reversed.toList();
    if (max != null && list.length > max!) list = list.sublist(0, max!);

    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('No events', style: TextStyle(color: AppTheme.textMuted)),
      );
    }
    return Column(children: list.map(_tile).toList());
  }

  Widget _tile(EventLog e) {
    final c = StatusColors.event(e.level);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 64,
          child: Text(e.timestamp,
              style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        SizedBox(
          width: 74,
          child: Text(e.level.name.toUpperCase(),
              style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w800)),
        ),
        Expanded(
          child: Text(e.message,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
        ),
      ]),
    );
  }
}
