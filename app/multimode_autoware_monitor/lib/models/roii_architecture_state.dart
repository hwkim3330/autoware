import 'enums.dart';

class RoiiArchitectureState {
  final ArchitectureStatus hpc;
  final ArchitectureStatus backbonePrimary;
  final ArchitectureStatus backboneSecondary;
  final Map<String, ArchitectureStatus> zones; // frontLeft, frontRight, rear
  final Map<String, List<String>> sensorMap;
  final ArchitectureStatus dataFlowStatus;

  const RoiiArchitectureState({
    required this.hpc,
    required this.backbonePrimary,
    required this.backboneSecondary,
    required this.zones,
    required this.sensorMap,
    required this.dataFlowStatus,
  });

  static const zoneOrder = ['frontLeft', 'frontRight', 'rear'];

  static String zoneLabel(String key) {
    switch (key) {
      case 'frontLeft':
        return 'Front-L Zone';
      case 'frontRight':
        return 'Front-R Zone';
      case 'rear':
        return 'Rear Zone';
      default:
        return key;
    }
  }

  factory RoiiArchitectureState.fromJson(Map<String, dynamic> j) {
    final bb = (j['backbone'] as Map?)?.cast<String, dynamic>() ?? const {};
    final zj = (j['zones'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sj = (j['sensorMap'] as Map?)?.cast<String, dynamic>() ?? const {};
    final zones = <String, ArchitectureStatus>{};
    for (final e in zj.entries) {
      zones[e.key] = architectureStatusFrom(e.value?.toString());
    }
    final sensorMap = <String, List<String>>{};
    for (final e in sj.entries) {
      sensorMap[e.key] =
          (e.value is List) ? (e.value as List).map((x) => x.toString()).toList() : const [];
    }
    return RoiiArchitectureState(
      hpc: architectureStatusFrom(j['hpc']?.toString()),
      backbonePrimary: architectureStatusFrom(bb['primary10G']?.toString()),
      backboneSecondary: architectureStatusFrom(bb['secondary10G']?.toString()),
      zones: zones,
      sensorMap: sensorMap,
      dataFlowStatus: architectureStatusFrom(j['dataFlowStatus']?.toString()),
    );
  }

  static const empty = RoiiArchitectureState(
    hpc: ArchitectureStatus.unknown,
    backbonePrimary: ArchitectureStatus.unknown,
    backboneSecondary: ArchitectureStatus.unknown,
    zones: {},
    sensorMap: {},
    dataFlowStatus: ArchitectureStatus.unknown,
  );
}
