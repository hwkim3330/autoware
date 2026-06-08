# App Concept

## What "multi-mode" means here
This app is **not** about driver comfort/acceleration profiles (Chill / Sport),
and it is **not** merely a fault display. **Multi-mode = which absolute-sensor
combination and which localization pipeline the autonomy stack is running
with, right now.**

- Absolute localization sensors: **LiDAR, GNSS, Camera**
- Relative localization sensors: **IMU, Odometry**

A sensor fault is treated as **one cause of a mode transition**, not as the
headline. The headline is always: *which sensor combo + which Autoware stack is
driving the car now.*

## The flow the screens must convey
```
driving environment
  → current localization sensor combination
  → current localization pipeline (Single / Dual / Triple)
  → selected Autoware stack
  → 6-State driving state
  → performance impact
  → event log
```

## Three axes shown simultaneously
1. **Localization multi-mode** — 7 absolute-sensor combinations
   (LiDAR / GNSS / Camera / LiDAR+GNSS / LiDAR+Camera / GNSS+Camera / all three).
2. **Localization pipeline structure** — Single (1 absolute + 1 relative),
   Dual (two pipelines fused), Triple (three absolute sensors fused).
3. **Selective Autoware stack** — the stack is chosen per situation/sensor combo,
   not a single monolith; each stack runs a subset of the 7 modules.

## 6-State driving state machine
Default IDs (renamable via `config/mode_catalog.json`):
S1 Normal Full Stack, S2 Urban RoI-NDT, S3 Rural Minimum,
S4 Dual Sensor Fusion, S5 Single Sensor Fallback,
S6 Localization Unavailable → Safe Stop.

## ROii vehicle as the visualization reference
Reference repo: **hwkim3330/roii2** (Automotive TSN network visualizer). This app
reuses ROii's vehicle/E-E network *concepts* (ACU_IT/HPC, 10G backbone, Front-L
/ Front-R / Rear zone controllers, multi-sensor layout, dashboard/scenario/flow
/fault views) but reimplements them as an Android-tablet 2D status monitor — it
does not embed the roii2 3D web app.

## Final system
```
CARLA → virtual LiDAR/Camera/GNSS/IMU/Odometry/VehicleState
      → ROS 2 topics → Autoware (Localization/Perception/Planning/Control)
      → control command → CARLA ego vehicle
Gateway → collects state → WebSocket → Flutter app (this repo)
```
