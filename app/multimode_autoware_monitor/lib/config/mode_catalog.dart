import 'dart:convert';
import 'package:flutter/services.dart';

/// One entry of the 6-State driving state machine. Names are NOT hardcoded —
/// they are loaded from assets config/mode_catalog.json so they can change
/// without touching Dart code.
class ModeCatalogEntry {
  final String stateId;
  final String displayName;
  final String description;
  final String requiredSensorCombination;
  final String selectedStack;
  final List<String> allowedTransitionTargets;
  final String safetyLevel;
  final String defaultColor;

  const ModeCatalogEntry({
    required this.stateId,
    required this.displayName,
    required this.description,
    required this.requiredSensorCombination,
    required this.selectedStack,
    required this.allowedTransitionTargets,
    required this.safetyLevel,
    required this.defaultColor,
  });

  factory ModeCatalogEntry.fromJson(Map<String, dynamic> j) => ModeCatalogEntry(
        stateId: (j['stateId'] ?? '').toString(),
        displayName: (j['displayName'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        requiredSensorCombination:
            (j['requiredSensorCombination'] ?? '').toString(),
        selectedStack: (j['selectedStack'] ?? '').toString(),
        allowedTransitionTargets: (j['allowedTransitionTargets'] is List)
            ? (j['allowedTransitionTargets'] as List)
                .map((e) => e.toString())
                .toList()
            : const [],
        safetyLevel: (j['safetyLevel'] ?? '').toString(),
        defaultColor: (j['defaultColor'] ?? 'gray').toString(),
      );
}

class ModeCatalog {
  final List<ModeCatalogEntry> states;
  const ModeCatalog(this.states);

  ModeCatalogEntry? byId(String stateId) {
    for (final s in states) {
      if (s.stateId == stateId) return s;
    }
    return null;
  }

  static ModeCatalog? _cache;

  static Future<ModeCatalog> load({bool reload = false}) async {
    if (_cache != null && !reload) return _cache!;
    try {
      final raw = await rootBundle.loadString('config/mode_catalog.json');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final list = (j['states'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => ModeCatalogEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
      _cache = ModeCatalog(list);
    } catch (_) {
      _cache = const ModeCatalog([]);
    }
    return _cache!;
  }
}
