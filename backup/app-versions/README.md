# PLEOS — ROii vehicle app, version history

KETI ROii autonomous-shuttle tablet apps, archived version by version.

| Version | Dir | What it is |
|---|---|---|
| v1 | `v1-pleos-architecture/` | Original PLEOS auto-manager: 3D ROii model (roii.glb) + E/E architecture viewer (TSN switches, zone controllers) |
| v2 | `v2-roii-monitor-3d/` | ROii Autoware Monitor: 3D model + live Autoware state via ROS WebSocket gateway, manual teleop (joystick + pedals + REVERSE) |
| v3 | (live repo) | Tesla-style dashboard: full-screen tap-to-go map, speed/gear HUD, architecture as separate screen — see roii_autoware_monitor |

Each version is a complete Flutter project (`flutter build apk --release`).
