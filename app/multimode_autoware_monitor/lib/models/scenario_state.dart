class ScenarioState {
  final String id;
  final String name;
  final String environment;
  final String drivingArea;

  const ScenarioState({
    required this.id,
    required this.name,
    required this.environment,
    required this.drivingArea,
  });

  factory ScenarioState.fromJson(Map<String, dynamic> j) => ScenarioState(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        environment: (j['environment'] ?? '').toString(),
        drivingArea: (j['drivingArea'] ?? '').toString(),
      );

  static const empty =
      ScenarioState(id: '-', name: '-', environment: '-', drivingArea: '-');
}
