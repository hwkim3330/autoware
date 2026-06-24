# SSU HMI Acceptance Test Checklist

Runnable checklist for validating the read-only HMI integration. Covers CARLA
regression, real-vehicle gateway behavior, mode-manager, pose-merger, and the
Flutter client.

## 1. CARLA regression (no behavior change to existing sim)

- [ ] Existing CARLA control path still works: `ros/ros_ws_gateway.py` launches
      and drives as before (the new HMI gateway must not touch it).
- [ ] `./scripts/run_niro_hmi_gateway.sh carla_niro` starts on port **8766**.
- [ ] CARLA gateway (8765, control) and HMI gateway (8766, read-only) run
      **simultaneously** without port conflict or shared-state interference.
- [ ] With CARLA driving, the HMI feed shows live `vehicle.speedKmh`,
      `localization.mode`, and a non-empty `trajectory`.

## 2. Real-vehicle gateway (ssu_niro, read-only)

- [ ] `./scripts/run_niro_hmi_gateway.sh ssu_niro` starts on port **8765**.
- [ ] Banner prints `command processing: DISABLED (read-only)`.
- [ ] Every broadcast frame has `capabilities.readOnly == true` and all command
      capabilities `false`.
- [ ] Inbound WebSocket messages from a client are **ignored** (logged as
      `[ignored inbound]`), no ROS publisher/service/action is created.
- [ ] `schemaVersion == "1.0"`, `profile == "ssu_niro"`,
      `source == "real_vehicle"` in every frame.
- [ ] `sequence` increments monotonically at ~10 Hz even with **zero** clients
      and with no `/clock` (wall-clock broadcast loop).
- [ ] Empty profile keys (autoware.*, vehicle.*) log `"<key> is not configured"`
      and leave their JSON fields at defaults (`UNKNOWN` / `null` / `false`) —
      no guessed values.
- [ ] `connection.dataStale` becomes `true` when sources stop updating beyond
      their configured timeouts, and `false` again once data resumes.
- [ ] `connection.rosConnected` reflects ROS liveness.

## 3. Mode manager / multimode

- [ ] `/multimode/mode` changes are reflected in `localization.mode`.
- [ ] `/multimode/status` JSON populates weights / fresh / fault / age fields
      (camelCase and snake_case keys both accepted).
- [ ] `sensors.lidar` / `sensors.gnss` map correctly to
      `NORMAL` / `FAULT` / `UNAVAILABLE` from fault/fresh/weight.
- [ ] `/multimode/transition_event` / `transition_status` append to `events`
      (capped at 20).

## 4. Pose merger / localization

- [ ] `multimode.fused_pose_topic` updates set `localization.converged` true.
- [ ] `multimode.fused_twist_topic` drives `vehicle.speedKmh`.
- [ ] Pose/twist age and `timestampDiffSec` / `pipelineGapM` (when present in
      status JSON) appear in the `localization` block.

## 5. Flutter / Android client

- [ ] Connects over Wi-Fi (`ws://<PC-IP>:8765/ws`), Ethernet, and USB
      (`adb reverse tcp:8765 tcp:8765` → `ws://127.0.0.1:8765/ws`).
- [ ] Renders speed, steering, localization mode, sensor status, autoware
      state, and event log from the `1.0` schema.
- [ ] Numeric `null` fields render as "—"/"N/A" (not `0`).
- [ ] Stale data indicator follows `connection.dataStale`.
- [ ] No control affordances are enabled (all `capabilities.*` false).
- [ ] Reconnects cleanly after the gateway restarts.

## 6. Tooling sanity

- [ ] `scripts/collect_ssu_ros_environment.sh` produces
      `ssu_ros_env_<label>.tar.gz` with topic/node/service/interface/TF dumps
      and `matched_topics.txt`.
- [ ] `scripts/record_ssu_hmi_bag.sh` records only existing lightweight topics
      (no PointCloud2/camera) and replays into the gateway.
- [ ] `niro/niro_sensor_adapter/converters/` modules `python3 -m py_compile`
      clean; `SsuCustomConverter.convert` still raises `NotImplementedError`
      (stub until real SSU defs arrive).
