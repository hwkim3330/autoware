# autoware-keti — CARLA ↔ ROS 2 ↔ Autoware + tablet monitor

KETI autonomous-driving integration: the **CARLA** simulator driving an **Autoware**
(ROS 2 Humble) stack, with a **Flutter tablet app** ("Multi-Mode Autoware Monitor")
showing the live localization multi-mode. Runs on an RTX 3090 box (Ubuntu 24.04 /
ROS 2 Jazzy host, Autoware in Docker).

```
CARLA (RTX 3090) ──sensors──► Autoware (docker, Humble) ──control──► CARLA ego
       │                                                              
       └── carla_ws_gateway.py ──WebSocket──► Flutter app (Galaxy Tab, 3D dashboard)
```

## What works (verified)
| Piece | Status |
|---|---|
| **CARLA 0.9.16** native, RTX 3090 (driver 535) | ✅ GPU render, world ready |
| **CARLA 0.10.0** (UE5) on driver 580 | ✅ (alt; for the tablet live demo) |
| **CARLA → Autoware** sensor/control bridge (`autoware_carla_interface`, docker) | ✅ `/sensing/{lidar,gnss,imu,camera×6}`, `/control/command/control_cmd` live |
| **All 8 CARLA town maps** (lanelet2 + pcd) | ✅ `scripts/download_carla_maps.sh` |
| **Tablet app** — installed on Galaxy Tab S7 FE | ✅ live data via gateway; 3D car + Tesla dashboard |
| Full autonomy closed loop (goal → plan → drive in rviz) | ⏳ bring-up (Autoware ML artifacts + e2e launch) |

## The driver lesson (important)
CARLA 0.9.x = **UE4.26**; its Vulkan RHI **hangs the render thread on NVIDIA 550/560+/580**
(known issue). Use **driver 535** for CARLA 0.9.x. CARLA 0.10.0 = UE5 and runs on 580.
Docker shares the **host** driver, so the host must be 535 for any 0.9.x (docker or native).
See `docs/carla_live_setup.md`, `docs/autoware_carla_integration.md`.

## Layout
```
app/multimode_autoware_monitor/   Flutter tablet app (3D car, Tesla dashboard, 9 screens)
ros/carla_ws_gateway.py           CARLA → WebSocket gateway (live telemetry → app)
ros/objects_lite.json             lite ego sensor set
scripts/                          start_carla_native.sh, start_autoware.sh, start_all.sh,
                                  download_carla_maps.sh, setup_swap.sh, start_bridge.sh
desktop/                          double-click launchers (also in ~/Desktop)
docs/                             setup + integration notes
```

## Quick start (on the GPU desktop, monitor on the RTX 3090, logged into GNOME)
```bash
# one-time
./scripts/download_carla_maps.sh            # all 8 town maps -> ~/autoware_map
# everything (CARLA + Autoware + rviz + tablet gateway)
./scripts/start_all.sh Town01
# or double-click the "Autoware + CARLA Demo" icon on the desktop
```
Tablet app: **Settings → USB_ADB** (`adb reverse tcp:8765 tcp:8765`) or **WIFI**
`ws://<PC-IP>:8765/ws`. Starts in DEMO (built-in mock) and auto-falls back to DEMO if
the gateway is unreachable.

## App
Flutter, no external state-management/charts. 3D vehicle via `model_viewer_plus`,
live updates via `StreamBuilder` + `web_socket_channel`. Screens: Dashboard (3D/2D car
+ hero), Vehicle (Tesla-style 3D), Localization (single/dual/triple pipeline), Sensors,
Autoware stack, ROii architecture, Metrics, Events, Settings. Build/install:
```bash
cd app/multimode_autoware_monitor && flutter create . --platforms=android
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Docs
- `docs/carla_live_setup.md` — CARLA on RTX 3090 (native/headless), gotchas
- `docs/autoware_carla_integration.md` — driver 535 + CARLA 0.9.16 + Autoware docker path
- `docs/ros2-jazzy.md` — carla-ros-bridge build on Jazzy (alt to native ROS2/interface)
- `docs/data_contract.md`, `docs/connection_guide.md`, `docs/app_concept.md`

🤖 Integration assembled with Claude Code.
