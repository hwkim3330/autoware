import 'dart:convert';
import 'package:flutter/services.dart';

/// ROii vehicle electrical/network topology, loaded from
/// config/roii_vehicle_topology.json (editable without code changes).
class RoiiZone {
  final String id;
  final String displayName;
  final List<String> sensors;
  const RoiiZone({
    required this.id,
    required this.displayName,
    required this.sensors,
  });

  factory RoiiZone.fromJson(Map<String, dynamic> j) => RoiiZone(
        id: (j['id'] ?? '').toString(),
        displayName: (j['displayName'] ?? '').toString(),
        sensors: (j['sensors'] is List)
            ? (j['sensors'] as List).map((e) => e.toString()).toList()
            : const [],
      );
}

class RoiiTopology {
  final String hpcName;
  final String backboneName;
  final List<RoiiZone> zones;
  const RoiiTopology({
    required this.hpcName,
    required this.backboneName,
    required this.zones,
  });

  static RoiiTopology? _cache;

  static Future<RoiiTopology> load({bool reload = false}) async {
    if (_cache != null && !reload) return _cache!;
    try {
      final raw =
          await rootBundle.loadString('config/roii_vehicle_topology.json');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final zones = (j['zones'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => RoiiZone.fromJson(e.cast<String, dynamic>()))
          .toList();
      _cache = RoiiTopology(
        hpcName: (j['hpc'] ?? 'ACU_IT / HPC').toString(),
        backboneName: (j['backbone'] ?? '10G Backbone').toString(),
        zones: zones,
      );
    } catch (_) {
      _cache = const RoiiTopology(
        hpcName: 'ACU_IT / HPC',
        backboneName: '10G Backbone',
        zones: [],
      );
    }
    return _cache!;
  }
}
