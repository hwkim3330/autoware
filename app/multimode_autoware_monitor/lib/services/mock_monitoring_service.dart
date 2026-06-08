import 'dart:async';

import '../config/app_config.dart';
import '../models/enums.dart';
import '../models/monitoring_data.dart';
import 'monitoring_service.dart';

/// Generates the 7 reference scenarios in-app and cycles through them every
/// [AppConfig.demoTick]. No server needed. This mirrors tools/mock_ws_server.py
/// and tools/sample_messages/*.json exactly.
class MockMonitoringService implements MonitoringService {
  final _data = StreamController<MonitoringData>.broadcast();
  final _conn = StreamController<ConnectionInfo>.broadcast();
  Timer? _timer;
  int _index = 0;
  MonitoringData? _latest;
  ConnectionInfo _connection = const ConnectionInfo(
    mode: ConnectionMode.demo,
    status: ConnectionStatus.disconnected,
    url: '(internal mock)',
  );

  @override
  Stream<MonitoringData> get dataStream => _data.stream;
  @override
  Stream<ConnectionInfo> get connectionStream => _conn.stream;
  @override
  ConnectionInfo get connection => _connection;
  @override
  MonitoringData? get latest => _latest;

  void resetScenario() => _index = 0;

  @override
  Future<void> start() async {
    _setConn(ConnectionStatus.connected);
    _emit(); // immediate first frame
    _timer?.cancel();
    _timer = Timer.periodic(AppConfig.demoTick, (_) => _emit());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _setConn(ConnectionStatus.disconnected);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _data.close();
    _conn.close();
  }

  void _setConn(ConnectionStatus s) {
    _connection = _connection.copyWith(status: s, lastReceived: _latest?.receivedAt);
    if (!_conn.isClosed) _conn.add(_connection);
  }

  void _emit() {
    final json = _scenarios[_index % _scenarios.length]();
    _index++;
    final data = MonitoringData.fromJson(json, receivedAt: DateTime.now())
        .copyWith(source: 'DEMO');
    _latest = data;
    if (!_data.isClosed) _data.add(data);
    _connection = _connection.copyWith(
        status: ConnectionStatus.connected, lastReceived: data.receivedAt);
    if (!_conn.isClosed) _conn.add(_connection);
  }

  // --- helpers to keep scenario maps compact ---
  static Map<String, dynamic> _sensor(String status, bool used, String role,
          [String reason = '']) =>
      {'status': status, 'used': used, 'role': role, 'reason': reason};

  static Map<String, dynamic> _event(String t, String level, String msg) =>
      {'timestamp': t, 'level': level, 'message': msg};

  static String _now() => DateTime.now().toUtc().toIso8601String();

  late final List<Map<String, dynamic> Function()> _scenarios = [
    _tripleFusionNormal,
    _urbanRoiNdt,
    _ruralMinimum,
    _dualLidarGnss,
    _gnssUnavailableLidarFallback,
    _lidarDegradedGnssCameraFallback,
    _localizationUnavailableStop,
  ];

  // Scenario 1
  Map<String, dynamic> _tripleFusionNormal() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_triple_fusion_normal_001',
          'name': 'Triple Fusion Normal',
          'environment': 'CARLA Town10HD',
          'drivingArea': 'URBAN'
        },
        'stateMachine': {
          'stateId': 'S1_NORMAL_FULL_STACK',
          'displayName': 'Normal Full Stack',
          'previousStateId': 'S1_NORMAL_FULL_STACK',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'All primary localization sensors healthy'
        },
        'localization': {
          'mode': 'LIDAR_GNSS_CAMERA',
          'pipelineType': 'TRIPLE',
          'absoluteSensors': ['LiDAR', 'GNSS', 'Camera'],
          'relativeSensors': ['IMU', 'Odometry'],
          'fusionMethod': 'EKF + NDT + GNSS',
          'fusionWeights': {'lidar': 0.5, 'gnss': 0.25, 'camera': 0.25},
          'confidence': 0.98,
          'latencyMs': 38.0
        },
        'sensors': {
          'lidar': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'gnss': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'camera': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'imu': _sensor('NORMAL', true, 'SUPPORT'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'TRIPLE_FUSION_STACK',
          'stackReason': 'All sensors nominal — full triple fusion localization',
          'modules': {
            'sensing': 'RUNNING',
            'localization': 'RUNNING',
            'perception': 'RUNNING',
            'planning': 'RUNNING',
            'control': 'RUNNING',
            'map': 'RUNNING',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': []
        },
        'roiiArchitecture': _roiiNormal(),
        'metrics': {
          'cpuUsagePercent': 72,
          'gpuUsagePercent': 61,
          'memoryUsagePercent': 70,
          'endToEndLatencyMs': 165,
          'localizationLatencyMs': 38.0,
          'modeTransitionTimeMs': 0,
          'architectureReconfigurationTimeMs': 0,
          'trajectoryError': 0.021,
          'resourceSavingPercent': 0.0,
          'safetyState': 'SAFE'
        },
        'events': [
          _event('00:00:01', 'SUCCESS', 'Triple fusion localization active'),
          _event('00:00:01', 'INFO', 'Autoware stack: TRIPLE_FUSION_STACK'),
        ],
      };

  // Scenario 2
  Map<String, dynamic> _urbanRoiNdt() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_urban_roi_ndt_002',
          'name': 'Urban RoI-NDT',
          'environment': 'CARLA Town05',
          'drivingArea': 'URBAN'
        },
        'stateMachine': {
          'stateId': 'S2_URBAN_ROI_NDT',
          'displayName': 'Urban RoI-NDT',
          'previousStateId': 'S1_NORMAL_FULL_STACK',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'Dense urban map — LiDAR RoI-NDT preferred'
        },
        'localization': {
          'mode': 'LIDAR_GNSS',
          'pipelineType': 'DUAL',
          'absoluteSensors': ['LiDAR', 'GNSS'],
          'relativeSensors': ['IMU', 'Odometry'],
          'fusionMethod': 'RoI-NDT + GNSS assist',
          'fusionWeights': {'lidar': 0.8, 'gnss': 0.2, 'camera': 0.0},
          'confidence': 0.95,
          'latencyMs': 45.0
        },
        'sensors': {
          'lidar': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'gnss': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'camera': _sensor('NORMAL', true, 'PERCEPTION'),
          'imu': _sensor('NORMAL', true, 'SUPPORT'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'ROI_NDT_URBAN_STACK',
          'stackReason': 'Urban driving — region-of-interest NDT localization',
          'modules': {
            'sensing': 'RUNNING',
            'localization': 'RUNNING',
            'perception': 'RUNNING',
            'planning': 'RUNNING',
            'control': 'RUNNING',
            'map': 'RUNNING',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': []
        },
        'roiiArchitecture': _roiiNormal(),
        'metrics': {
          'cpuUsagePercent': 64,
          'gpuUsagePercent': 55,
          'memoryUsagePercent': 66,
          'endToEndLatencyMs': 172,
          'localizationLatencyMs': 45.0,
          'modeTransitionTimeMs': 410,
          'architectureReconfigurationTimeMs': 0,
          'trajectoryError': 0.028,
          'resourceSavingPercent': 8.0,
          'safetyState': 'SAFE'
        },
        'events': [
          _event('00:00:05', 'INFO', 'Entered dense urban area'),
          _event('00:00:05', 'SUCCESS', 'Stack: ROI_NDT_URBAN_STACK'),
        ],
      };

  // Scenario 3
  Map<String, dynamic> _ruralMinimum() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_rural_minimum_003',
          'name': 'Rural Minimum Stack',
          'environment': 'CARLA Town07',
          'drivingArea': 'RURAL'
        },
        'stateMachine': {
          'stateId': 'S3_RURAL_MINIMUM',
          'displayName': 'Rural Minimum',
          'previousStateId': 'S2_URBAN_ROI_NDT',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'Open rural road — minimum stack to save resources'
        },
        'localization': {
          'mode': 'GNSS_CAMERA',
          'pipelineType': 'DUAL',
          'absoluteSensors': ['GNSS', 'Camera'],
          'relativeSensors': ['Odometry'],
          'fusionMethod': 'GNSS + visual lane',
          'fusionWeights': {'lidar': 0.0, 'gnss': 0.6, 'camera': 0.4},
          'confidence': 0.88,
          'latencyMs': 33.0
        },
        'sensors': {
          'lidar': _sensor('STANDBY', false, 'UNUSED', 'Not needed on open road'),
          'gnss': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'camera': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'imu': _sensor('NORMAL', false, 'SUPPORT'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'MINIMUM_RURAL_STACK',
          'stackReason': 'Sparse environment — reduced perception/planning load',
          'modules': {
            'sensing': 'RUNNING',
            'localization': 'RUNNING',
            'perception': 'LIMITED',
            'planning': 'LIMITED',
            'control': 'RUNNING',
            'map': 'LIMITED',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': ['heavy_object_tracking', 'traffic_light_recognition']
        },
        'roiiArchitecture': _roiiNormal(secondary: 'STANDBY'),
        'metrics': {
          'cpuUsagePercent': 41,
          'gpuUsagePercent': 28,
          'memoryUsagePercent': 52,
          'endToEndLatencyMs': 140,
          'localizationLatencyMs': 33.0,
          'modeTransitionTimeMs': 520,
          'architectureReconfigurationTimeMs': 900,
          'trajectoryError': 0.044,
          'resourceSavingPercent': 31.0,
          'safetyState': 'LIMITED_DRIVE'
        },
        'events': [
          _event('00:00:09', 'INFO', 'Rural area detected'),
          _event('00:00:09', 'SUCCESS', 'Minimum rural stack — CPU load reduced'),
        ],
      };

  // Scenario 4
  Map<String, dynamic> _dualLidarGnss() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_dual_lidar_gnss_004',
          'name': 'Dual LiDAR-GNSS Fusion',
          'environment': 'CARLA Town04',
          'drivingArea': 'URBAN'
        },
        'stateMachine': {
          'stateId': 'S4_DUAL_SENSOR_FUSION',
          'displayName': 'Dual Sensor Fusion',
          'previousStateId': 'S1_NORMAL_FULL_STACK',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'LiDAR and GNSS pipelines are both available'
        },
        'localization': {
          'mode': 'LIDAR_GNSS',
          'pipelineType': 'DUAL',
          'absoluteSensors': ['LiDAR', 'GNSS'],
          'relativeSensors': ['Odometry'],
          'fusionMethod': 'KalmanFilter',
          'fusionWeights': {'lidar': 0.5, 'gnss': 0.5, 'camera': 0.0},
          'confidence': 0.93,
          'latencyMs': 42.5
        },
        'sensors': {
          'lidar': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'gnss': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'camera': _sensor('NORMAL', false, 'PERCEPTION',
              'Not selected for current localization mode'),
          'imu': _sensor('NORMAL', false, 'SUPPORT'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'DUAL_LIDAR_GNSS_STACK',
          'stackReason':
              'Dual localization fusion selected for stable urban driving',
          'modules': {
            'sensing': 'RUNNING',
            'localization': 'RUNNING',
            'perception': 'RUNNING',
            'planning': 'RUNNING',
            'control': 'RUNNING',
            'map': 'RUNNING',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': []
        },
        'roiiArchitecture': _roiiNormal(),
        'metrics': {
          'cpuUsagePercent': 58,
          'gpuUsagePercent': 44,
          'memoryUsagePercent': 67,
          'endToEndLatencyMs': 185,
          'localizationLatencyMs': 42.5,
          'modeTransitionTimeMs': 512,
          'architectureReconfigurationTimeMs': 1220,
          'trajectoryError': 0.032,
          'resourceSavingPercent': 18.5,
          'safetyState': 'SAFE'
        },
        'events': [
          _event('00:00:13', 'INFO', 'Dual LiDAR-GNSS localization fusion active'),
          _event('00:00:14', 'SUCCESS',
              'Autoware stack selected: DUAL_LIDAR_GNSS_STACK'),
        ],
      };

  // Scenario 5
  Map<String, dynamic> _gnssUnavailableLidarFallback() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_gnss_unavailable_lidar_fallback_005',
          'name': 'GNSS Unavailable → LiDAR Fallback',
          'environment': 'CARLA Town03 (tunnel)',
          'drivingArea': 'URBAN'
        },
        'stateMachine': {
          'stateId': 'S5_SINGLE_SENSOR_FALLBACK',
          'displayName': 'Single Sensor Fallback',
          'previousStateId': 'S4_DUAL_SENSOR_FUSION',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'GNSS unavailable'
        },
        'localization': {
          'mode': 'LIDAR_ONLY',
          'pipelineType': 'SINGLE',
          'absoluteSensors': ['LiDAR'],
          'relativeSensors': ['Odometry'],
          'fusionMethod': 'NDT + Odometry',
          'fusionWeights': {'lidar': 1.0, 'gnss': 0.0, 'camera': 0.0},
          'confidence': 0.84,
          'latencyMs': 49.0
        },
        'sensors': {
          'lidar': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'gnss': _sensor('FAULT', false, 'UNUSED', 'GNSS signal lost (tunnel)'),
          'camera': _sensor('NORMAL', false, 'PERCEPTION'),
          'imu': _sensor('NORMAL', true, 'SUPPORT'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'LIDAR_LOCALIZATION_STACK',
          'stackReason': 'GNSS lost — LiDAR + Odometry localization only',
          'modules': {
            'sensing': 'RUNNING',
            'localization': 'RUNNING',
            'perception': 'RUNNING',
            'planning': 'RUNNING',
            'control': 'RUNNING',
            'map': 'RUNNING',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': ['gnss_poser']
        },
        'roiiArchitecture': _roiiNormal(),
        'metrics': {
          'cpuUsagePercent': 60,
          'gpuUsagePercent': 47,
          'memoryUsagePercent': 68,
          'endToEndLatencyMs': 198,
          'localizationLatencyMs': 49.0,
          'modeTransitionTimeMs': absToMs,
          'architectureReconfigurationTimeMs': 0,
          'trajectoryError': 0.061,
          'resourceSavingPercent': 5.0,
          'safetyState': 'LIMITED_DRIVE'
        },
        'events': [
          _event('00:00:17', 'WARNING', 'GNSS signal lost'),
          _event('00:00:17', 'SUCCESS',
              'Localization pipeline switched to LiDAR + Odometry'),
        ],
      };

  static const int absToMs = 305;

  // Scenario 6
  Map<String, dynamic> _lidarDegradedGnssCameraFallback() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_lidar_degraded_gnss_camera_fallback_006',
          'name': 'LiDAR Degraded → GNSS/Camera Fallback',
          'environment': 'CARLA Town06 (rain)',
          'drivingArea': 'SUBURBAN'
        },
        'stateMachine': {
          'stateId': 'S4_DUAL_SENSOR_FUSION',
          'displayName': 'Dual Sensor Fusion',
          'previousStateId': 'S1_NORMAL_FULL_STACK',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'LiDAR degraded — switch to GNSS + Camera'
        },
        'localization': {
          'mode': 'GNSS_CAMERA',
          'pipelineType': 'DUAL',
          'absoluteSensors': ['GNSS', 'Camera'],
          'relativeSensors': ['IMU', 'Odometry'],
          'fusionMethod': 'GNSS + Visual SLAM',
          'fusionWeights': {'lidar': 0.0, 'gnss': 0.5, 'camera': 0.5},
          'confidence': 0.81,
          'latencyMs': 51.0
        },
        'sensors': {
          'lidar':
              _sensor('DEGRADED', false, 'UNUSED', 'Heavy rain — point cloud noisy'),
          'gnss': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'camera': _sensor('NORMAL', true, 'ABSOLUTE_LOCALIZATION'),
          'imu': _sensor('NORMAL', true, 'SUPPORT'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'DUAL_GNSS_CAMERA_STACK',
          'stackReason': 'LiDAR unreliable in rain — GNSS + Camera fusion',
          'modules': {
            'sensing': 'RUNNING',
            'localization': 'RUNNING',
            'perception': 'LIMITED',
            'planning': 'RUNNING',
            'control': 'RUNNING',
            'map': 'RUNNING',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': ['lidar_ndt_scan_matcher']
        },
        'roiiArchitecture': _roiiDegraded(),
        'metrics': {
          'cpuUsagePercent': 55,
          'gpuUsagePercent': 50,
          'memoryUsagePercent': 65,
          'endToEndLatencyMs': 205,
          'localizationLatencyMs': 51.0,
          'modeTransitionTimeMs': 640,
          'architectureReconfigurationTimeMs': 1100,
          'trajectoryError': 0.073,
          'resourceSavingPercent': 12.0,
          'safetyState': 'LIMITED_DRIVE'
        },
        'events': [
          _event('00:00:21', 'WARNING', 'LiDAR degraded'),
          _event('00:00:22', 'SUCCESS', 'GNSS + Camera localization selected'),
        ],
      };

  // Scenario 7
  Map<String, dynamic> _localizationUnavailableStop() => {
        'timestamp': _now(),
        'source': 'DEMO',
        'scenario': {
          'id': 'scenario_localization_unavailable_stop_007',
          'name': 'Localization Unavailable',
          'environment': 'CARLA Town03 (sensor blackout)',
          'drivingArea': 'URBAN'
        },
        'stateMachine': {
          'stateId': 'S6_LOCALIZATION_UNAVAILABLE_STOP',
          'displayName': 'Localization Unavailable — Safe Stop',
          'previousStateId': 'S5_SINGLE_SENSOR_FALLBACK',
          'transitionStatus': 'COMPLETED',
          'transitionReason': 'No usable absolute localization sensor'
        },
        'localization': {
          'mode': 'UNAVAILABLE',
          'pipelineType': 'UNAVAILABLE',
          'absoluteSensors': [],
          'relativeSensors': ['IMU', 'Odometry'],
          'fusionMethod': '-',
          'fusionWeights': {'lidar': 0.0, 'gnss': 0.0, 'camera': 0.0},
          'confidence': 0.0,
          'latencyMs': 0.0
        },
        'sensors': {
          'lidar': _sensor('FAULT', false, 'UNUSED', 'Sensor failure'),
          'gnss': _sensor('FAULT', false, 'UNUSED', 'No fix'),
          'camera': _sensor('FAULT', false, 'UNUSED', 'Sensor failure'),
          'imu': _sensor('NORMAL', true, 'SUPPORT', 'Dead-reckoning only'),
          'odometry': _sensor('NORMAL', true, 'RELATIVE_LOCALIZATION'),
        },
        'autoware': {
          'selectedStack': 'FALLBACK_STOP_STACK',
          'stackReason': 'Localization unavailable — minimal risk maneuver',
          'modules': {
            'sensing': 'LIMITED',
            'localization': 'ERROR',
            'perception': 'STOPPED',
            'planning': 'LIMITED',
            'control': 'RUNNING',
            'map': 'STOPPED',
            'vehicleInterface': 'RUNNING'
          },
          'excludedModules': [
            'lidar_localization',
            'gnss_poser',
            'camera_localization',
            'object_recognition'
          ]
        },
        'roiiArchitecture': _roiiFault(),
        'metrics': {
          'cpuUsagePercent': 33,
          'gpuUsagePercent': 10,
          'memoryUsagePercent': 48,
          'endToEndLatencyMs': 120,
          'localizationLatencyMs': 0.0,
          'modeTransitionTimeMs': 280,
          'architectureReconfigurationTimeMs': 1500,
          'trajectoryError': 0.0,
          'resourceSavingPercent': 0.0,
          'safetyState': 'SAFE_STOP_REQUIRED'
        },
        'events': [
          _event('00:00:25', 'ERROR', 'Localization unavailable'),
          _event('00:00:25', 'ERROR', 'Safe stop required'),
        ],
      };

  // --- ROii architecture presets ---
  static Map<String, dynamic> _roiiNormal({String secondary = 'STANDBY'}) => {
        'hpc': 'NORMAL',
        'backbone': {'primary10G': 'NORMAL', 'secondary10G': secondary},
        'zones': {'frontLeft': 'NORMAL', 'frontRight': 'NORMAL', 'rear': 'NORMAL'},
        'sensorMap': _defaultSensorMap,
        'dataFlowStatus': 'NORMAL'
      };

  static Map<String, dynamic> _roiiDegraded() => {
        'hpc': 'NORMAL',
        'backbone': {'primary10G': 'NORMAL', 'secondary10G': 'NORMAL'},
        'zones': {
          'frontLeft': 'DEGRADED',
          'frontRight': 'NORMAL',
          'rear': 'NORMAL'
        },
        'sensorMap': _defaultSensorMap,
        'dataFlowStatus': 'DEGRADED'
      };

  static Map<String, dynamic> _roiiFault() => {
        'hpc': 'NORMAL',
        'backbone': {'primary10G': 'DEGRADED', 'secondary10G': 'RECOVERING'},
        'zones': {'frontLeft': 'FAULT', 'frontRight': 'FAULT', 'rear': 'DEGRADED'},
        'sensorMap': _defaultSensorMap,
        'dataFlowStatus': 'FAULT'
      };

  static const _defaultSensorMap = {
    'frontLeft': ['LiDAR-FL', 'LiDAR-FC', 'Cam-FL', 'Cam-SL1', 'Cam-SL2', 'Radar-FL'],
    'frontRight': [
      'LiDAR-FR',
      'Cam-FC',
      'Cam-FR',
      'Cam-SR1',
      'Cam-SR2',
      'Radar-FC',
      'Radar-FR'
    ],
    'rear': ['LiDAR-RC', 'Cam-RC', 'Radar-RL', 'Radar-RR'],
  };
}
