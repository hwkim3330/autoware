# Multi-Mode Autoware Monitor

Android-tablet monitoring app (Flutter) for a **ROS 2 / Autoware / CARLA**
autonomous-driving stack. It shows, in real time, **which localization sensor
combination and which Autoware stack the vehicle is running with** — the
"multi-mode" of autonomous localization.

> Project: `multimode_autoware_monitor` · App name: **Multi-Mode Autoware Monitor**

---

## 1. Purpose
Visualize, on an in-vehicle tablet, the live localization multi-mode, pipeline
structure, selected Autoware stack, 6-state driving state, performance impact,
and event log of an Autoware+CARLA system. Sensor faults appear as *causes of
mode transitions*, not as the main subject.

## 2. What "multi-mode" means
Not comfort/acceleration profiles, not just "fault mode". It is the choice of
**absolute-sensor combination + localization pipeline + Autoware stack**.
- Absolute sensors: **LiDAR, GNSS, Camera**
- Relative sensors: **IMU, Odometry**
See `docs/app_concept.md`.

## 3. The 7 localization sensor combinations
LiDAR · GNSS · Camera · LiDAR+GNSS · LiDAR+Camera · GNSS+Camera · LiDAR+GNSS+Camera.
Pipelines: **Single** (1 absolute + 1 relative), **Dual** (two pipelines fused),
**Triple** (three absolute sensors fused).

## 4. 6-State driving state machine
S1 Normal Full Stack · S2 Urban RoI-NDT · S3 Rural Minimum ·
S4 Dual Sensor Fusion · S5 Single Sensor Fallback ·
S6 Localization Unavailable → Safe Stop.
Names are **not hardcoded** — edit `config/mode_catalog.json`.

## 5. ROii vehicle visualization
Reference: **hwkim3330/roii2**. Reuses ACU_IT/HPC, 10G backbone, Front-L /
Front-R / Rear zone controllers and multi-sensor layout as a 2D tablet view
(`config/roii_vehicle_topology.json`).

## 6. System architecture
```
CARLA → LiDAR/Camera/GNSS/IMU/Odometry/VehicleState → ROS 2 topics
      → Autoware (Localization/Perception/Planning/Control) → control → CARLA
Gateway → WebSocket (ws://host:8765/ws) → this Flutter app
```

## 7. Run the Flutter project
```bash
flutter create .          # generate android/ (etc.) into this folder — keeps lib/
flutter pub get
flutter run               # on a connected device/emulator
```
> If creating fresh elsewhere: `flutter create multimode_autoware_monitor`,
> then copy `lib/`, `config/`, `pubspec.yaml` in.

The app starts in **DEMO** mode (built-in mock data) — works with no server.

## 8. Build & install on an Android tablet
```bash
flutter build apk --release
adb devices
adb install build/app/outputs/flutter-apk/app-release.apk
```
The app locks to landscape (handled in `main.dart` via `SystemChrome`).

## 9. Wi-Fi Mode (primary)
1. Start the mock server on the PC (see §11).
2. Ensure tablet + PC share a Wi-Fi; get the PC IP (`hostname -I`).
3. App → Settings → Data Source = **WIFI** → `ws://<PC-IP>:8765/ws` → Connect.
   Example: `ws://192.168.0.10:8765/ws`

## 10. USB ADB Mode (backup)
Works over USB even without shared Wi-Fi:
```bash
adb reverse tcp:8765 tcp:8765
```
App → Settings → Data Source = **USB_ADB** (URL auto = `ws://127.0.0.1:8765/ws`) → Connect.

## 11. Mock WebSocket server
```bash
cd tools
python3 -m venv .venv
source .venv/bin/activate
pip install websockets
python mock_ws_server.py
```
It prints Local / Wi-Fi URLs and the `adb reverse` hint, then streams the 7
scenarios (1/sec). See `tools/sample_messages/*.json`.

## 12. Data contract
One JSON object per second; full schema + example in `docs/data_contract.md`.
The app parses it into `lib/models/monitoring_data.dart`. Unknown enum values
degrade gracefully (never crash).

## 13. Connecting real CARLA / ROS 2 / Autoware later
Replace the mock with a small **gateway** node that subscribes to Autoware /
carla-ros-bridge topics and re-publishes the contract JSON on
`ws://0.0.0.0:8765/ws`. Suggested mappings:
- `localization.mode/pipeline` ← active `ekf_localizer` / `ndt_scan_matcher` /
  `gnss_poser` / camera-localizer inputs
- `sensors.*` ← topic liveness + diagnostics (`/diagnostics`)
- `autoware.modules` ← lifecycle/component states per subsystem
- `metrics.*` ← `/system/...` resource + latency topics, trajectory error from
  localization vs ground truth
The app needs no change — only the gateway must emit the same JSON. (The Flutter
side already handles WIFI/USB/Custom; set `source` to `VEHICLE` for real runs.)

## 14. Troubleshooting
- Stuck CONNECTING → DEMO fallback: check IP/port/firewall, server running.
- STALE DATA badge: connected but no frame >4 s — check the publisher.
- USB ADB: re-run `adb reverse tcp:8765 tcp:8765` after replug.
- More in `docs/connection_guide.md`.

---

### Project layout
```
lib/{models,services,screens,widgets,theme,config}/   Dart app
config/{mode_catalog,roii_vehicle_topology}.json      runtime-editable config (assets)
tools/mock_ws_server.py + sample_messages/*.json      mock server + 7 scenarios
docs/{data_contract,connection_guide,app_concept}.md  docs
```
No external state-management or charting packages. Real-time via `StreamBuilder`.
Only dependency: `web_socket_channel`.
