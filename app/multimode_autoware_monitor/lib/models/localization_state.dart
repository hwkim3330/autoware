import 'enums.dart';

class LocalizationState {
  final LocalizationMode mode;
  final PipelineType pipelineType;
  final List<String> absoluteSensors;
  final List<String> relativeSensors;
  final String fusionMethod;
  final double fusionLidar;
  final double fusionGnss;
  final double fusionCamera;
  final double confidence; // 0..1
  final double latencyMs;

  const LocalizationState({
    required this.mode,
    required this.pipelineType,
    required this.absoluteSensors,
    required this.relativeSensors,
    required this.fusionMethod,
    required this.fusionLidar,
    required this.fusionGnss,
    required this.fusionCamera,
    required this.confidence,
    required this.latencyMs,
  });

  factory LocalizationState.fromJson(Map<String, dynamic> j) {
    final w = (j['fusionWeights'] as Map?)?.cast<String, dynamic>() ?? const {};
    double d(dynamic v) => (v is num) ? v.toDouble() : 0.0;
    List<String> l(dynamic v) =>
        (v is List) ? v.map((e) => e.toString()).toList() : const [];
    return LocalizationState(
      mode: localizationModeFrom(j['mode']?.toString()),
      pipelineType: pipelineTypeFrom(j['pipelineType']?.toString()),
      absoluteSensors: l(j['absoluteSensors']),
      relativeSensors: l(j['relativeSensors']),
      fusionMethod: (j['fusionMethod'] ?? '-').toString(),
      fusionLidar: d(w['lidar']),
      fusionGnss: d(w['gnss']),
      fusionCamera: d(w['camera']),
      confidence: d(j['confidence']),
      latencyMs: d(j['latencyMs']),
    );
  }

  static const empty = LocalizationState(
    mode: LocalizationMode.unknown,
    pipelineType: PipelineType.unknown,
    absoluteSensors: [],
    relativeSensors: [],
    fusionMethod: '-',
    fusionLidar: 0,
    fusionGnss: 0,
    fusionCamera: 0,
    confidence: 0,
    latencyMs: 0,
  );
}
