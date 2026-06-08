import 'package:flutter/material.dart';

import '../services/monitoring_service.dart';
import '../widgets/event_timeline.dart';
import '../widgets/summary_card.dart';
import 'screen_header.dart';

class EventTimelineScreen extends StatelessWidget {
  final MonitoringService service;
  const EventTimelineScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'Event Timeline',
      builder: (context, data) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title:
                  'EVENT TIMELINE  ·  ${data.scenario.name}  ·  ${data.stateMachine.stateId}',
              child: EventTimelineList(events: data.events, reverse: true),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'EVENT FLOW (reference order)',
              child: const Text(
                'Sensor status changed → Localization mode selected → '
                'Pipeline switched → Autoware stack selected → '
                'Architecture state changed → Safety state changed → '
                'Performance measured',
                style: TextStyle(color: Colors.white70, height: 1.5),
              ),
            ),
          ],
        );
      },
    );
  }
}
