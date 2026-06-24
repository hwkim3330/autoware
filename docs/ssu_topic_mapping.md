# SSU Topic Mapping

How to point the read-only HMI gateway at the SSU vehicle's real topics by
editing `config/hmi/ssu_niro.yaml`.

## How the mapping works

`ssu_niro.yaml` maps **topic-keys** the gateway understands to the vehicle's
**topic names**. The adapter (`ros/hmi_adapters/ssu_niro_adapter.py`) binds each
key to a concrete, known message type. Changing a topic *name* never changes the
message *type* the adapter expects — so only remap a key to a topic whose type
matches the supported list below.

```yaml
profile: ssu_niro
source: real_vehicle
multimode:
  mode_topic:              /multimode/mode                                  # std_msgs/String
  status_topic:            /multimode/status                                # std_msgs/String (JSON payload)
  transition_event_topic:  /multimode/transition_event                      # std_msgs/String
  transition_status_topic: /multimode/transition_status                     # std_msgs/String
  fused_pose_topic:        /localization/multimode/pose_with_covariance     # geometry_msgs/PoseWithCovarianceStamped
  fused_twist_topic:       /localization/multimode/twist_with_covariance    # geometry_msgs/TwistWithCovarianceStamped
autoware:
  odometry_topic:        ""   # nav_msgs/Odometry        (empty = skipped)
  trajectory_topic:      ""   # nav_msgs/Path or autoware Trajectory
  operation_mode_topic:  ""   # autoware operation-mode state
  route_state_topic:     ""   # autoware route state
  mrm_state_topic:       ""   # autoware MRM state
vehicle:
  velocity_topic:        ""   # geometry_msgs/TwistStamped
  steering_topic:        ""   # vehicle steering status
```

## Supported message types

| Key | Expected type |
|-----|---------------|
| `multimode.mode_topic` | `std_msgs/msg/String` |
| `multimode.status_topic` | `std_msgs/msg/String` (JSON body, camelCase or snake_case keys) |
| `multimode.transition_event_topic` / `transition_status_topic` | `std_msgs/msg/String` |
| `multimode.fused_pose_topic` | `geometry_msgs/msg/PoseWithCovarianceStamped` |
| `multimode.fused_twist_topic` | `geometry_msgs/msg/TwistWithCovarianceStamped` |
| `autoware.odometry_topic` | `nav_msgs/msg/Odometry` |
| `vehicle.velocity_topic` | `geometry_msgs/msg/TwistStamped` |

Sensor-side standard types handled by `niro/niro_sensor_adapter/converters/`:
`sensor_msgs/msg/PointCloud2`, `sensor_msgs/msg/NavSatFix`, `sensor_msgs/msg/Imu`,
and velocity from `geometry_msgs/msg/TwistStamped` or `nav_msgs/msg/Odometry`.

## Empty topics are skipped (never guessed)

An empty string (`""`) for any key means **"not configured"**: the base adapter
logs `"<key> is not configured"` and creates no subscription. The corresponding
JSON fields stay at their defaults (`UNKNOWN` / `null` / `false`). Leave a key
empty until you have confirmed the real topic name **and** that its type matches
the table above. Do not fill a key with a guessed topic/type.

## Filling from collect_ssu_ros_environment.sh output

1. On the vehicle, run `scripts/collect_ssu_ros_environment.sh <label>` and copy
   back `ssu_ros_env_<label>.tar.gz`.
2. Open `matched_topics.txt` — it lists topics matching the localization / lidar
   / gnss / pose / twist / multimode / fault / trajectory / operation / route /
   mrm / vehicle / velocity / steering keywords, each annotated with its type.
3. For each gateway key, find a matching topic whose **type** is in the table
   above (cross-check `interfaces/<type>.txt`, captured via
   `ros2 interface show`) and paste the topic name into `ssu_niro.yaml`.
4. If the vehicle publishes a **custom** (non-standard) type for a sensor, do
   NOT map it directly. Capture its `ros2 interface show` output and implement
   `niro/niro_sensor_adapter/converters/ssu_custom_converter.py` (currently a
   stub) to normalize it into a supported standard type first.
