# autoware-keti — CARLA ↔ Autoware full autonomous driving + Tesla tablet app

KETI autonomous-driving stack on **one 16-core / RTX-3090 box**: the CARLA
simulator drives a full **Autoware** (ROS 2 Humble, Docker) stack — NDT
localization, lanelet2 routing, behavior/motion planning, MPC control — and a
**Flutter tablet app** (Tesla-style dashboard) commands and monitors it live.

```
CARLA 0.9.16 (cores 0,8) ──lidar/imu/gnss──► Autoware (docker, cores 1-7,9-15)
        ▲                                        │ NDT → route → trajectory → MPC
        └────── throttle/steer/brake ◄───────────┘
                                                 │ ros_ws_gateway.py (WebSocket)
                          Galaxy Tab ◄───────────┘ Tesla dashboard, tap-to-go
```

## Quick start — `./run.sh` 하나로 전부

```bash
cd ~/autoware-keti
./run.sh                 # Town04 풀스택 (~4분: CARLA+Autoware+게이트웨이+rviz)
./run.sh drive           # 자율주행 출발 (태블릿 DRIVE 버튼과 동일)
./run.sh status          # 전체 프로세스 상태 한눈에
```

| 명령 | 동작 |
|---|---|
| `./run.sh [TownXX]` | 해당 타운 풀스택 기동 (기본 Town04) |
| `./run.sh drive` / `stop` | 자율주행 출발 / 정지 |
| `./run.sh real` | 실제 지도 자율주행 (CARLA 없이, planning simulator) |
| `./run.sh app` | 태블릿 앱 빌드+설치+USB 연결 |
| `./run.sh test` | 전 타운 자율주행 검증 (~40분, 결과 docs/town_test_results.md) |
| `./run.sh status` / `kill` | 프로세스 상태 / 전부 정리 |

**태블릿**: USB 연결 후 앱 실행 — DRIVE 버튼 또는 **지도 탭 = 그 지점으로 자율주행**.
수동운전: 독의 게임패드 아이콘 → 조이스틱/기울기(TILT) 조향 + ACCEL/REVERSE 페달.
Wi-Fi는 독의 ⚙에서 `ws://<PC-IP>:8765/ws`.

Verified: route SET → trajectory 150+ pts → AUTONOMOUS → up to ~28 km/h
lane-following (cap `max_vel: 8.33`). The car is driven end-to-end by Autoware
(mission → behavior → trajectory follower → vehicle gate); CARLA only simulates
the world — its traffic-manager autopilot is off. Per-town autonomous-drive
validation: `scripts/test_all_towns.sh` → **`docs/town_test_results.md`**.
Real-world maps (no CARLA): `scripts/run_real_map_sim.sh` (planning simulator,
same gateway/tablet tap-to-go; MGRS maps supported).

## What made it work (root causes, all baked into the script)

| Blocker | Root cause | Fix |
|---|---|---|
| "planned route is empty" everywhere, black rviz map | `map_projector_info.yaml` missing → vector map loaded as MGRS while nodes use `local_x/local_y` | `projector_type: local` for every town |
| route still empty on-lane | random spawn faces against the lane → no start lanelet match | `ros/find_spawn.py` computes an aligned on-lane spawn per town (table in script) |
| behavior_path stuck "waiting for map", trajectory never appears (big towns) | ~8 MB LaneletMapBin fragments dropped by 64 KB UDP socket buffers | 32 MB DDS buffers (`config/fastdds_udp.xml`) + host `rmem/wmem_max` |
| engage "target mode not available" | trajectory (and availability) appears 2-3 s after the route | gateway retries engage 10×2 s |
| CARLA segfault / RPC starvation | Autoware startup burst starves CARLA | CPU partition: CARLA `taskset 0,8` (one HT pair), container `1-7,9-15` |
| ros2 CLI false negatives | SHM port lock race across ~100 nodes | UDP-only Fast-DDS profile |

Known limit: re-routing mid-session (stop → clear → new drive) can crash the
behavior_planning container (rclcpp race; it respawns but planning may stay
stuck). One route per session is solid — rerun the script for a new route.

## Layout

```
scripts/run_localization_demo.sh   one-command bring-up (spawn table, configs, gateway, rviz)
ros/ros_ws_gateway.py              ROS↔WebSocket gateway: live state + drive/goto/stop/clear/teleop
ros/perception_stub.py             empty objects + clear occupancy grid (perception:=false)
ros/find_spawn.py                  aligned on-lane spawn finder (any town osm)
ros/drive_monitor.py               CLI drive + live monitor (route/traj/mode/speed)
ros/diag_*.py                      routing / connectivity / route-lifecycle diagnostics
config/fastdds_udp.xml             UDP-only DDS, 32 MB buffers (big vector maps)
config/sensor_mapping_lidar_only.yaml  1 LiDAR (300k) + IMU + GNSS, cameras OFF
container_patches/                 camera-free interface launch + clean rviz config
docs/autoware_carla_integration.md full debugging history & root-cause writeups
backup/app-versions/               tablet app archive (v1 pleos architecture, v2 3D monitor)
app/, webapp/, desktop/, launch/   earlier gateway/app/launcher experiments (kept for reference)
```

## Tablet app

Live app: `/home/kim/roii_autoware_monitor` — Tesla Model 3/Y layout: left
panel (PRND strip, big speed, AUTOPILOT pill, 3D ROii), full-bleed dark nav map
(grey lane network, Tesla-blue planned route, red destination pin; **tap the map
to auto-drive there**), bottom icon dock (ROii architecture screen, manual
joystick, Drive / Stop / Clear).

```bash
cd /home/kim/roii_autoware_monitor
flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk
adb reverse tcp:8765 tcp:8765
```

Older versions archived in `backup/app-versions/` (v1 = original PLEOS
architecture viewer, v2 = 3D monitor with joystick/pedals teleop).

## Docs

- `docs/autoware_carla_integration.md` — the full debugging history, every root cause
- `docs/carla_live_setup.md` — CARLA on RTX 3090 (native/headless), driver gotchas
- `docs/ros2-jazzy.md` — carla-ros-bridge build on Jazzy (alternative path)

## Hardware / driver notes

CARLA 0.9.x is UE4.26 — its Vulkan RHI hangs on NVIDIA driver 550+; use
**driver 535**. CARLA boot is flaky (intermittent Signal 11) — the script
retries until the RPC port stays up. After ~10 crash cycles the GPU driver
state degrades: reboot to recover.

🤖 Integration assembled with Claude Code.
