# autoware-keti — CARLA ↔ ROS 2 ↔ Autoware integration (monorepo)

KETI integration of the **CARLA 0.9.16** driving simulator with **ROS 2 Jazzy** and
**Autoware**, plus a web app for monitoring/control. Built and validated on a
machine **without an NVIDIA GPU** (Intel UHD 630) using software (lavapipe) rendering.

## Repository layout (monorepo)

```
.
├── ros/        # ROS 2 integration: carla-ros-bridge usage, Autoware interface, launch
├── webapp/     # Web app (monitoring / control) — connects to ROS 2 over rosbridge/websocket
├── scripts/    # One-shot setup + launch helpers (CARLA, swap, bridge)
├── launch/     # Top-level launch configs tying CARLA + bridge (+ Autoware) together
└── docs/       # Setup notes, hardware reality, troubleshooting
```

## Hardware reality (important)

This box has **no discrete GPU** — only Intel UHD 630. CARLA's UE4.26 renderer
crashes on the iGPU (`Out of Local Memory, MemTypeIndex=1`, the iGPU's Vulkan
device-local heap is too small). The working configuration forces **lavapipe
(llvmpipe) CPU software rendering**:

- `VK_ICD_FILENAMES` **and** `VK_DRIVER_FILES` → lavapipe ICD (so the iGPU is never selected)
- a large **swapfile** + disabling `systemd-oomd` (CPU rendering needs >16GB)

It runs, but slowly (sub-realtime). For real sensor throughput, add an NVIDIA GPU
or raise the BIOS iGPU/DVMT allocation. For full Autoware, note that Autoware
Universe officially targets **ROS 2 Humble** — see `docs/autoware.md`.

## Quick start

```bash
# 0) one-time: swap + disable oomd (software rendering needs lots of RAM)
sudo ./scripts/setup_swap.sh 32

# 1) start the CARLA server (software/lavapipe, port 2000)
./scripts/start_carla.sh
#    first launch compiles shaders on CPU — get_world() may take a few minutes

# 2) start the ROS 2 bridge (in another terminal)
./scripts/start_bridge.sh

# 3) verify ROS 2 topics
source /opt/ros/jazzy/setup.bash
ros2 topic list | grep carla
```

## Status (verified on this box)

- [x] CARLA 0.9.16 server installed (`/opt/carla-simulator`), running on Intel UHD 630 via lavapipe
- [x] `carla-ros-bridge` built from source for ROS 2 Jazzy (see `docs/ros2-jazzy.md`)
- [x] Ego vehicle spawned; `/carla/ego_vehicle/*` topics published
  - ✅ working: `odometry`, `imu`, `gnss`, `vehicle_status`, `speedometer`, `lidar` (1801 pts/scan)
  - ⚠️ `rgb_front/image`: **0 fps on lavapipe** — CPU rendering can't keep up with camera. Needs a GPU.
- [x] Web monitor (`webapp/`): live telemetry over rosbridge websocket + MJPEG camera via web_video_server
- [ ] `autoware_carla_interface` topic remap (`ros/`) — pending

### Resolved: Fast-CDR ABI mismatch on Jazzy
The system was **half-upgraded**: `ros-jazzy-fastcdr` was 2.2.5 (Jan) while
newer packages (`derived_object_msgs` 4.0.0, `rosbridge_suite` 2.6.0, Apr builds)
needed 2.2.7 → bridge/rosbridge crashed with `undefined symbol ...Cdr9serializeEj`.
Fixed by a full `apt dist-upgrade` of the ROS 2 Jazzy stack to a consistent ABI
(fastcdr 2.2.7) + clean rebuild of `carla-ros-ws`. `sensor.pseudo.objects`
(derived_object_msgs) is back in `ros/objects_lite.json`.

## License / origin

Integration glue is MIT. Vendored references: `carla-simulator/ros-bridge`,
`autowarefoundation/autoware`.
