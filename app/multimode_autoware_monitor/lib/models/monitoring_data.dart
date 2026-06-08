import 'autoware_state.dart';
import 'event_log.dart';
import 'localization_state.dart';
import 'metrics_state.dart';
import 'roii_architecture_state.dart';
import 'scenario_state.dart';
import 'sensor_state.dart';
import 'state_machine_state.dart';

/// Top-level aggregate that mirrors the WebSocket JSON data contract
/// (see docs/data_contract.md). One instance == one frame.
class MonitoringData {
  final String timestamp; // ISO-8601 from the wire
  final String source; // DEMO / WIFI / USB_ADB / VEHICLE
  final DateTime receivedAt; // local clock, when the app parsed it
  final ScenarioState scenario;
  final StateMachineState stateMachine;
  final LocalizationState localization;
  final SensorSet sensors;
  final AutowareState autoware;
  final RoiiArchitectureState roii;
  final MetricsState metrics;
  final List<EventLog> events;

  const MonitoringData({
    required this.timestamp,
    required this.source,
    required this.receivedAt,
    required this.scenario,
    required this.stateMachine,
    required this.localization,
    required this.sensors,
    required this.autoware,
    required this.roii,
    required this.metrics,
    required this.events,
  });

  factory MonitoringData.fromJson(Map<String, dynamic> j, {DateTime? receivedAt}) {
    Map<String, dynamic> m(String k) =>
        (j[k] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    return MonitoringData(
      timestamp: (j['timestamp'] ?? '').toString(),
      source: (j['source'] ?? '-').toString(),
      receivedAt: receivedAt ?? DateTime.now(),
      scenario: ScenarioState.fromJson(m('scenario')),
      stateMachine: StateMachineState.fromJson(m('stateMachine')),
      localization: LocalizationState.fromJson(m('localization')),
      sensors: SensorSet.fromJson(m('sensors')),
      autoware: AutowareState.fromJson(m('autoware')),
      roii: RoiiArchitectureState.fromJson(m('roiiArchitecture')),
      metrics: MetricsState.fromJson(m('metrics')),
      events: (j['events'] is List)
          ? (j['events'] as List)
              .whereType<Map>()
              .map((e) => EventLog.fromJson(e.cast<String, dynamic>()))
              .toList()
          : const [],
    );
  }

  MonitoringData copyWith({String? source, DateTime? receivedAt}) =>
      MonitoringData(
        timestamp: timestamp,
        source: source ?? this.source,
        receivedAt: receivedAt ?? this.receivedAt,
        scenario: scenario,
        stateMachine: stateMachine,
        localization: localization,
        sensors: sensors,
        autoware: autoware,
        roii: roii,
        metrics: metrics,
        events: events,
      );
}
