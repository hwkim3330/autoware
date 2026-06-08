import 'enums.dart';

class AutowareState {
  final String selectedStack;
  final String stackReason;
  final Map<String, ModuleStatus> modules; // sensing, localization, ...
  final List<String> excludedModules;

  const AutowareState({
    required this.selectedStack,
    required this.stackReason,
    required this.modules,
    required this.excludedModules,
  });

  /// Canonical module order for display.
  static const moduleOrder = [
    'sensing',
    'localization',
    'perception',
    'planning',
    'control',
    'map',
    'vehicleInterface',
  ];

  factory AutowareState.fromJson(Map<String, dynamic> j) {
    final m = (j['modules'] as Map?)?.cast<String, dynamic>() ?? const {};
    final modules = <String, ModuleStatus>{};
    for (final k in moduleOrder) {
      if (m.containsKey(k)) modules[k] = moduleStatusFrom(m[k]?.toString());
    }
    return AutowareState(
      selectedStack: (j['selectedStack'] ?? '-').toString(),
      stackReason: (j['stackReason'] ?? '').toString(),
      modules: modules,
      excludedModules: (j['excludedModules'] is List)
          ? (j['excludedModules'] as List).map((e) => e.toString()).toList()
          : const [],
    );
  }

  static String moduleLabel(String key) {
    switch (key) {
      case 'vehicleInterface':
        return 'Vehicle Interface';
      default:
        return key[0].toUpperCase() + key.substring(1);
    }
  }

  static const empty = AutowareState(
    selectedStack: '-',
    stackReason: '',
    modules: {},
    excludedModules: [],
  );
}
