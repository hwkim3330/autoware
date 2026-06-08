import 'enums.dart';

class MetricsState {
  final double cpuUsagePercent;
  final double gpuUsagePercent;
  final double memoryUsagePercent;
  final double endToEndLatencyMs;
  final double localizationLatencyMs;
  final double modeTransitionTimeMs;
  final double architectureReconfigurationTimeMs;
  final double trajectoryError;
  final double resourceSavingPercent;
  final SafetyState safetyState;

  const MetricsState({
    required this.cpuUsagePercent,
    required this.gpuUsagePercent,
    required this.memoryUsagePercent,
    required this.endToEndLatencyMs,
    required this.localizationLatencyMs,
    required this.modeTransitionTimeMs,
    required this.architectureReconfigurationTimeMs,
    required this.trajectoryError,
    required this.resourceSavingPercent,
    required this.safetyState,
  });

  factory MetricsState.fromJson(Map<String, dynamic> j) {
    double d(dynamic v) => (v is num) ? v.toDouble() : 0.0;
    return MetricsState(
      cpuUsagePercent: d(j['cpuUsagePercent']),
      gpuUsagePercent: d(j['gpuUsagePercent']),
      memoryUsagePercent: d(j['memoryUsagePercent']),
      endToEndLatencyMs: d(j['endToEndLatencyMs']),
      localizationLatencyMs: d(j['localizationLatencyMs']),
      modeTransitionTimeMs: d(j['modeTransitionTimeMs']),
      architectureReconfigurationTimeMs:
          d(j['architectureReconfigurationTimeMs']),
      trajectoryError: d(j['trajectoryError']),
      resourceSavingPercent: d(j['resourceSavingPercent']),
      safetyState: safetyStateFrom(j['safetyState']?.toString()),
    );
  }

  static const empty = MetricsState(
    cpuUsagePercent: 0,
    gpuUsagePercent: 0,
    memoryUsagePercent: 0,
    endToEndLatencyMs: 0,
    localizationLatencyMs: 0,
    modeTransitionTimeMs: 0,
    architectureReconfigurationTimeMs: 0,
    trajectoryError: 0,
    resourceSavingPercent: 0,
    safetyState: SafetyState.unknown,
  );
}
