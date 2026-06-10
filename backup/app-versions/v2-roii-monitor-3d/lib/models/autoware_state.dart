/// Live state of the Autoware autonomous stack, parsed from the ROS gateway
/// WebSocket frame (ros/ros_ws_gateway.py).
class AutowareState {
  final DateTime ts;
  final double x, y, z, yawDeg, speedKmh;
  final bool localized;
  final int locInitState;
  final String locMode;          // LIDAR_GNSS / UNAVAILABLE ...
  final double ndtHz;
  final String operationMode;    // AUTONOMOUS / STOP ...
  final bool autonomousAvailable;
  final String routeState;       // UNSET / SET / ARRIVED ...
  final int trajPoints;          // planned trajectory length
  final String cmdResult;        // last command feedback from gateway
  final Map<String, String> sensors; // lidar/gnss/imu/camera -> OK|FAULT|OFF
  final List<String> faults;     // glb material names to highlight

  const AutowareState({
    required this.ts,
    required this.x,
    required this.y,
    required this.z,
    required this.yawDeg,
    required this.speedKmh,
    required this.localized,
    required this.locInitState,
    required this.locMode,
    required this.ndtHz,
    required this.operationMode,
    required this.autonomousAvailable,
    required this.routeState,
    required this.trajPoints,
    required this.cmdResult,
    required this.sensors,
    required this.faults,
  });

  bool get isAutonomous => operationMode == 'AUTONOMOUS';
  bool get isDriving => speedKmh > 0.3;

  factory AutowareState.fromJson(Map<String, dynamic> j) {
    final ego = (j['ego'] ?? {}) as Map<String, dynamic>;
    final loc = (j['localization'] ?? {}) as Map<String, dynamic>;
    final op = (j['operationMode'] ?? {}) as Map<String, dynamic>;
    final route = (j['route'] ?? {}) as Map<String, dynamic>;
    final sensors = (j['sensors'] ?? {}) as Map<String, dynamic>;
    double d(v) => (v is num) ? v.toDouble() : 0.0;
    return AutowareState(
      ts: DateTime.tryParse(j['ts']?.toString() ?? '') ?? DateTime.now(),
      x: d(ego['x']), y: d(ego['y']), z: d(ego['z']),
      yawDeg: d(ego['yawDeg']), speedKmh: d(ego['speedKmh']),
      localized: loc['converged'] == true,
      locInitState: (loc['initState'] is num) ? (loc['initState'] as num).toInt() : 0,
      locMode: loc['mode']?.toString() ?? 'UNKNOWN',
      ndtHz: d(loc['ndtHz']),
      operationMode: op['mode']?.toString() ?? 'UNKNOWN',
      autonomousAvailable: op['autonomousAvailable'] == true,
      routeState: route['state']?.toString() ?? 'UNKNOWN',
      trajPoints: (route['trajPoints'] is num) ? (route['trajPoints'] as num).toInt() : 0,
      cmdResult: j['cmdResult']?.toString() ?? '',
      sensors: sensors.map((k, v) => MapEntry(k, v.toString())),
      faults: ((j['faults'] ?? []) as List).map((e) => e.toString()).toList(),
    );
  }

  /// Disconnected placeholder.
  factory AutowareState.disconnected() => AutowareState(
        ts: DateTime.now(), x: 0, y: 0, z: 0, yawDeg: 0, speedKmh: 0,
        localized: false, locInitState: 0, locMode: 'DISCONNECTED', ndtHz: 0,
        operationMode: 'DISCONNECTED', autonomousAvailable: false,
        routeState: 'UNKNOWN', trajPoints: 0, cmdResult: '',
        sensors: const {}, faults: const [],
      );
}
