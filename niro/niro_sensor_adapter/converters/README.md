# niro_sensor_adapter / converters

Converters adapt a raw sensor/driver message into the **standard** message the
niro localization/perception pipeline expects. Each converter is a pure
per-message function (`convert(msg)`); the adapter node owns the
subscriptions/publishers and calls `convert` for each incoming message. See
`base_converter.py` for the full contract.

## Currently-supported input message types

```
LiDAR:    sensor_msgs/msg/PointCloud2
GNSS:     sensor_msgs/msg/NavSatFix
IMU:      sensor_msgs/msg/Imu
Velocity: geometry_msgs/msg/TwistStamped OR nav_msgs/msg/Odometry
```

| Converter | Class | Input | Output |
|-----------|-------|-------|--------|
| `pointcloud_converter.py` | `PointCloudConverter` | `sensor_msgs/msg/PointCloud2` | same `PointCloud2` (passthrough) |
| `navsatfix_converter.py`  | `NavSatFixConverter`  | `sensor_msgs/msg/NavSatFix`   | same `NavSatFix` (passthrough) |
| `imu_converter.py`        | `ImuConverter`        | `sensor_msgs/msg/Imu`         | same `Imu` (passthrough) |
| `velocity_converter.py`   | `VelocityConverter`   | `geometry_msgs/msg/TwistStamped` OR `nav_msgs/msg/Odometry` | longitudinal speed (float, m/s) |
| `ssu_custom_converter.py` | `SsuCustomConverter`  | *(SSU custom, unknown)* | **STUB — raises `NotImplementedError`** |

## SSU custom types

`ssu_custom_converter.py` is a deliberate stub. SSU-specific message types are
added **only after the real `ros2 interface show <ssu_msg>` definitions arrive**
(e.g. from `scripts/collect_ssu_ros_environment.sh`). Do not guess field names.
