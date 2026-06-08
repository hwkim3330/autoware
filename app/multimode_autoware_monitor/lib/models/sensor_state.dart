import 'enums.dart';

class SensorState {
  final String key; // lidar, gnss, camera, imu, odometry
  final SensorStatus status;
  final bool used;
  final SensorRole role;
  final String reason;

  const SensorState({
    required this.key,
    required this.status,
    required this.used,
    required this.role,
    required this.reason,
  });

  factory SensorState.fromJson(String key, Map<String, dynamic> j) =>
      SensorState(
        key: key,
        status: sensorStatusFrom(j['status']?.toString()),
        used: j['used'] == true,
        role: sensorRoleFrom(j['role']?.toString()),
        reason: (j['reason'] ?? '').toString(),
      );

  String get displayName {
    switch (key) {
      case 'lidar':
        return 'LiDAR';
      case 'gnss':
        return 'GNSS';
      case 'camera':
        return 'Camera';
      case 'imu':
        return 'IMU';
      case 'odometry':
        return 'Odometry';
      default:
        return key;
    }
  }
}

class SensorSet {
  /// Ordered: 3 absolute sensors first, then 2 relative.
  static const order = ['lidar', 'gnss', 'camera', 'imu', 'odometry'];
  final Map<String, SensorState> sensors;
  const SensorSet(this.sensors);

  factory SensorSet.fromJson(Map<String, dynamic> j) {
    final map = <String, SensorState>{};
    for (final k in order) {
      final v = j[k];
      if (v is Map) {
        map[k] = SensorState.fromJson(k, v.cast<String, dynamic>());
      }
    }
    return SensorSet(map);
  }

  List<SensorState> get ordered =>
      order.where(sensors.containsKey).map((k) => sensors[k]!).toList();

  static const empty = SensorSet({});
}
