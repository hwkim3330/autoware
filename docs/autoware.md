# Autoware integration notes

## Version reality

- **Autoware Universe** officially targets **ROS 2 Humble (Ubuntu 22.04)**.
- This machine runs **ROS 2 Jazzy (Ubuntu 24.04)**, where `carla-ros-bridge`
  builds fine (see `ros2-jazzy.md`) but a full native Autoware build is **not
  officially supported** and is heavy (large build, lots of RAM).
- On a no-GPU box running CARLA via lavapipe (sub-realtime), running the full
  Autoware autonomy stack live is impractical. Treat Autoware here as the
  *target* integration; do heavy Autoware work on a Humble machine / Docker, or
  on a box with an NVIDIA GPU.

## Integration approach

CARLA ↔ Autoware is bridged by **`autoware_carla_interface`** (part of Autoware
Universe under `simulator/`). The data path is:

```
CARLA server ──RPC──► carla-ros-bridge ──/carla/* topics──► autoware_carla_interface
        ▲                                                          │
        └──────────── /carla/ego_vehicle/vehicle_control ◄─────────┘ (Autoware control)
```

`autoware_carla_interface` remaps carla-ros-bridge sensor/odometry topics to the
Autoware topic namespace (`/sensing/...`, `/localization/...`,
`/vehicle/status/...`) and converts Autoware's `AckermannControlCommand` back to
CARLA's `CarlaEgoVehicleControl`.

## Recommended path on Humble (separate machine / Docker)

```bash
# Humble + Autoware (abridged)
mkdir -p autoware_ws/src && cd autoware_ws
git clone https://github.com/autowarefoundation/autoware.git src/autoware
# import + rosdep + colcon build per Autoware docs, then:
ros2 launch autoware_carla_interface carla_autoware.launch.xml
```

## Status here

- carla-ros-bridge publishing `/carla/*` on Jazzy — done.
- `ros/` will hold the topic-remap config + a Jazzy-compatible build of the
  interface (WIP). Until then the bridge alone exposes sensors/control for
  custom planning nodes and the web app.
