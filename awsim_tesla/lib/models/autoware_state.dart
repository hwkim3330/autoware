/// A 3D object detected by GPU CenterPoint (LiDAR), in map-frame world coords.
/// cls follows autoware ObjectClassification: 1=CAR 2=TRUCK 3=BUS 5=MOTORCYCLE
/// 6=BICYCLE 7=PEDESTRIAN (0=UNKNOWN). sx/sy are the box length/width (m).
class DetectedObj {
  final double x, y, yawDeg, sx, sy;
  final int cls;
  const DetectedObj(this.x, this.y, this.yawDeg, this.cls, this.sx, this.sy);
  bool get isPedestrian => cls == 7;
  bool get isCycle => cls == 5 || cls == 6;
}

/// A traffic light in map-frame world coords. color: 1=RED 2=AMBER/YELLOW 3=GREEN
/// (autoware_perception_msgs TrafficLightElement). z is the bulb height (m).
class TrafficLight {
  final double x, y, z;
  final int color, shape;
  const TrafficLight(this.x, this.y, this.z, this.color, this.shape);
  bool get isRed => color == 1;
  bool get isAmber => color == 2;
  bool get isGreen => color == 3;
}

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
  final Map<String, String> parts;   // per-sensor health (FrontCenterLidar...)
  final List<String> faults;     // glb material names to highlight
  final List<List<double>> trajPath; // local trajectory [[x,y],...] in map frame
  final List<List<double>> routePath; // FULL route to goal (lanelet centerlines)
  final double steerDeg;         // actual steering tire angle
  final int turn;                // 1 none, 2 left, 3 right
  final String mrm;              // '' or MRM state
  final double plannedKmh;       // planner target speed at ego
  final Map<String, dynamic>? roii;  // ROii 4-lidar health (null unless roii mode)
  final Map<String, dynamic>? niro;  // Niro 이중측위 telemetry (null unless niro mode):
  //   mode (normal|lidar_fault), lidar_weight, gnss_weight, lidar_fresh, gnss_fresh,
  //   injected, pipeline_gap_m, sensors{ouster_os2_128,rtk_gnss,imu}, lastEvent{...}
  final Map<String, dynamic>? site;  // real-map geo-origin {lat, lon, site} (null in CARLA/Town mode)
  final Map<String, dynamic>? system; // live system monitor {nodes:int, topics:[{n,ok,v}]}
  final List<DetectedObj> objects;   // CenterPoint surround objects (Tesla view)
  final List<TrafficLight> trafficLights; // nearby traffic lights (map frame)
  final Map<String, dynamic>? upcomingLight; // {color:int, dist:int} nearest light ahead

  // --- read-only HMI gateway schema (carla_niro:8766 / ssu_niro:8765) ---
  // These are null/empty for the existing CARLA gateway frame (which has NO
  // `capabilities`). When present, the frame is from the read-only HMI gateway.
  final Map<String, dynamic>? capabilities; // {readOnly,setRoute,engage,stop,mrm,teleop,faultInjection}
  final String? profile;            // e.g. 'ssu_niro' / 'carla_niro'
  final String? hmiSource;          // 'real_vehicle' / 'simulation'
  final String schemaVersion;       // '' when absent
  final Map<String, dynamic>? connection; // {rosConnected,dataStale,lastUpdateMs}
  final Map<String, dynamic>? hmiLoc; // raw read-only localization block (weights/freshness)
  final Map<String, dynamic>? hmiVehicle; // raw read-only vehicle block (nullable speed/steer)
  final List<dynamic> events;       // read-only event log (empty when absent)

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
    this.parts = const {},
    required this.faults,
    this.trajPath = const [],
    this.routePath = const [],
    this.steerDeg = 0,
    this.turn = 0,
    this.mrm = '',
    this.plannedKmh = 0,
    this.roii,
    this.niro,
    this.site,
    this.system,
    this.objects = const [],
    this.trafficLights = const [],
    this.upcomingLight,
    this.capabilities,
    this.profile,
    this.hmiSource,
    this.schemaVersion = '',
    this.connection,
    this.hmiLoc,
    this.hmiVehicle,
    this.events = const [],
  });

  bool get isAutonomous => operationMode == 'AUTONOMOUS';
  bool get isDriving => speedKmh > 0.3;

  // --- read-only HMI gateway helpers ---
  /// True when the frame comes from the read-only HMI gateway and forbids control.
  bool get readOnly => capabilities?['readOnly'] == true;
  /// True when this read-only frame originates from the real vehicle (not sim).
  bool get isRealVehicle => hmiSource == 'real_vehicle';
  /// True when the gateway reports its ROS data is stale.
  bool get dataStale => connection?['dataStale'] == true;

  factory AutowareState.fromJson(Map<String, dynamic> j) {
    final ego = (j['ego'] ?? {}) as Map<String, dynamic>;
    final loc = (j['localization'] ?? {}) as Map<String, dynamic>;
    final op = (j['operationMode'] ?? {}) as Map<String, dynamic>;
    final route = (j['route'] ?? {}) as Map<String, dynamic>;
    final sensors = (j['sensors'] ?? {}) as Map<String, dynamic>;
    final parts = (j['parts'] ?? {}) as Map<String, dynamic>;
    final veh = (j['vehicle'] ?? {}) as Map<String, dynamic>;
    double d(v) => (v is num) ? v.toDouble() : 0.0;

    // The read-only HMI gateway frame is distinguished by a `capabilities` block.
    // Its layout differs from CARLA: speed lives in vehicle.speedKmh, op-mode/
    // route/mrm live under `autoware`, localization carries fusion weights.
    final bool isHmi = j['capabilities'] is Map;
    if (isHmi) {
      final aw = (j['autoware'] ?? {}) as Map<String, dynamic>;
      final conn = (j['connection'] ?? {}) as Map<String, dynamic>;
      // `mrmState` UNKNOWN/NORMAL/NONE -> empty (no banner); otherwise pass through.
      final rawMrm = aw['mrmState']?.toString() ?? '';
      final mrmUp = rawMrm.toUpperCase();
      final mrm = (mrmUp == 'UNKNOWN' || mrmUp == 'NORMAL' ||
              mrmUp == 'NONE' || mrmUp.isEmpty)
          ? ''
          : rawMrm;
      return AutowareState(
        ts: DateTime.tryParse(j['timestamp']?.toString() ?? '') ?? DateTime.now(),
        x: 0, y: 0, z: 0, yawDeg: 0,
        speedKmh: (veh['speedKmh'] is num) ? (veh['speedKmh'] as num).toDouble() : 0.0,
        localized: loc['converged'] == true,
        locInitState: 0,
        locMode: loc['mode']?.toString() ?? 'UNKNOWN',
        ndtHz: 0,
        operationMode: aw['operationMode']?.toString() ?? 'UNKNOWN',
        autonomousAvailable: false,
        routeState: aw['routeState']?.toString() ?? 'UNKNOWN',
        trajPoints: 0,
        cmdResult: '',
        sensors: sensors.map((k, v) => MapEntry(k, v.toString())),
        faults: const [],
        steerDeg: (veh['steeringDeg'] is num) ? (veh['steeringDeg'] as num).toDouble() : 0.0,
        mrm: mrm,
        capabilities: Map<String, dynamic>.from(j['capabilities'] as Map),
        profile: j['profile']?.toString(),
        hmiSource: j['source']?.toString(),
        schemaVersion: j['schemaVersion']?.toString() ?? '',
        connection: Map<String, dynamic>.from(conn),
        hmiLoc: loc.isNotEmpty ? Map<String, dynamic>.from(loc) : null,
        hmiVehicle: veh.isNotEmpty ? Map<String, dynamic>.from(veh) : null,
        events: (j['events'] is List) ? List<dynamic>.from(j['events'] as List) : const [],
      );
    }

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
      parts: parts.map((k, v) => MapEntry(k, v.toString())),
      faults: ((j['faults'] ?? []) as List).map((e) => e.toString()).toList(),
      trajPath: ((route['trajPath'] ?? []) as List)
          .map<List<double>>((p) => ((p as List).map((c) => d(c)).toList()))
          .toList(),
      routePath: ((route['routePath'] ?? []) as List)
          .map<List<double>>((p) => ((p as List).map((c) => d(c)).toList()))
          .toList(),
      steerDeg: d(veh['steerDeg']),
      turn: (veh['turn'] is num) ? (veh['turn'] as num).toInt() : 0,
      mrm: veh['mrm']?.toString() ?? '',
      plannedKmh: d(veh['plannedKmh']),
      roii: j['roii'] is Map ? Map<String, dynamic>.from(j['roii']) : null,
      niro: j['niro'] is Map ? Map<String, dynamic>.from(j['niro']) : null,
      site: j['site'] is Map ? Map<String, dynamic>.from(j['site']) : null,
      system: j['system'] is Map ? Map<String, dynamic>.from(j['system']) : null,
      objects: ((j['objects'] ?? []) as List).map<DetectedObj>((o) {
        final m = o as Map<String, dynamic>;
        return DetectedObj(d(m['x']), d(m['y']), d(m['yaw']),
            (m['cls'] is num) ? (m['cls'] as num).toInt() : 0,
            d(m['sx']), d(m['sy']));
      }).toList(),
      trafficLights: ((j['trafficLights'] ?? []) as List).map<TrafficLight>((o) {
        final m = o as Map<String, dynamic>;
        return TrafficLight(d(m['x']), d(m['y']), d(m['z']),
            (m['color'] is num) ? (m['color'] as num).toInt() : 0,
            (m['shape'] is num) ? (m['shape'] as num).toInt() : 1);
      }).toList(),
      upcomingLight: j['upcomingLight'] is Map
          ? Map<String, dynamic>.from(j['upcomingLight'] as Map)
          : null,
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
