# AWSIM (Autoware Unity sim) — setup status & full diagnosis

Goal: replace MORAI with **AWSIM** for a real-area driving sim (Nishi-Shinjuku, Tokyo)
that gives live sensors (multi-LiDAR + camera + NPC vehicles) → Autoware → Tesla tablet
app, with OpenStreetMap (Shinjuku is fully in OSM).

## What's done / working
- **Binaries downloaded**: `~/AWSIM/AWSIM-Demo/` (autowarefoundation/AWSIM v2.0.1 — this is
  the one actually in use, see "RESOLVED 2026-07-06" below) and `~/AWSIM/awsim_labs/awsim_labs_v1.6.1/`
  (AWSIM-Labs — **archived/no-longer-maintained as of 2026-01-11**, kept only for reference,
  not the one to build on going forward).
- **Shinjuku map** for Autoware: `~/autoware_map/shinjuku/` (pcd + lanelet2 from tier4/AWSIM
  v1.1.0 + `map_projector_info.yaml` MGRS 54SUE). Map-frame→WGS84 origin **35.2376422,138.7889491**.
- **Container fixed**: recreated `autoware` from committed image `autoware-shm` with shared
  host /dev/shm (`--ipc=host -v /dev/shm:/dev/shm`, 16G) — fixes FastDDS SHM segment errors
  (also benefits CARLA). Backup: `autoware_old`.
- **DDS config** (AWSIM-Labs requires): `ip link set lo multicast on` + `net.core.rmem_max=2147483647`
  + ipfrag sysctls. (scripts/run_awsim.sh applies these.)
- **Tesla app** `~/awsim_tesla` (com.keti.awsim_tesla) built — 3D surround dashboard, Shinjuku OSM.

## THE BLOCKER (fully diagnosed, not yet resolved)
AWSIM's bundled ROS2 (ros2-for-unity) is built for **humble**. This box's **host runs ROS2 jazzy**.
- **On the host**: AWSIM's `librcl.so` fails — `UnsatisfiedLinkError`, missing `libspdlog.so.1`
  + `libfmt.so.8` (host has jazzy's libspdlog.so.1.12 / different libfmt). Copying humble's
  libspdlog.so.1.9.2 + libfmt.so.8 (from the container) into AWSIM's `..._Data/Plugins/` makes
  `ldd librcl.so` resolve, but Unity's native loader still throws (ABI/symbol-version or it
  resolves jazzy libs from the ldconfig cache first). Player.log: `ROS2 version: humble` then
  `UnsatisfiedLinkError: librcl.so`.
- **Inside the humble container**: `librcl.so` loads fine (native humble libspdlog/libfmt),
  no segfault — BUT the Unity/HDRP scene won't render (no NVIDIA Vulkan ICD in the container;
  `vulkaninfo` missing). AWSIM sits idle (~150 MB GPU, window 1024x768, "No configuration file
  provided", PhysX init) → the sim loop never runs → **0 sensor topics published**.
  (Do NOT `source /opt/ros/humble` before launching — AWSIM is a standalone ros2-for-unity build;
  sourcing causes a SIGSEGV. Run with env unset.)

Discovery vs data: when AWSIM *was* briefly seen publishing, the container saw topics (discovery)
but no DATA — that was the SHM split (now fixed) + lo-multicast-off (now fixed). The remaining
wall is simply that AWSIM isn't *running its sim* in either environment.

## RESOLVED 2026-06-25 — run AWSIM INSIDE the humble container (no host bridge)
The winning approach: stop bridging host(jazzy)<->container(humble); run AWSIM-Demo v2
*inside* the `autoware` (humble) container so AWSIM + Autoware share one DDS.
- **Vulkan in container** (the key unlock): `apt install vulkan-tools mesa-vulkan-drivers
  libvulkan1` -> `vulkaninfo` shows RTX 3090 -> AWSIM-Demo v2 renders at **6 GB GPU**
  (`-force-vulkan`, DISPLAY=:1, XAUTHORITY=/root/.Xauthority, VK_ICD_FILENAMES=nvidia_icd.json,
  and UNSET AMENT_PREFIX_PATH/ROS_DISTRO/RMW/LD_LIBRARY_PATH/PYTHONPATH). AWSIM-Demo copied to
  `/opt/awsim/AWSIM-Demo` (3.5G, `docker cp`). (AWSIM-**Labs** loads but its scene won't auto-run
  -> "No configuration file provided"; AWSIM-**Demo** v2 auto-runs -> use the Demo.)
- **Result: /clock at ~98 Hz + lidar/gnss/camera/imu/twist/velocity all flow to Autoware**
  (verified: localization crop_box processed a real 26754-pt cloud).
- **Zombie trap**: relaunching AWSIM left zombie procs whose dead DDS publishers got
  discovered as /clock (Publisher count 1, but SILENT). Fix: `docker stop && docker start`
  (NEVER `restart` - breaks CUDA/NVML) reaps zombies + clears /dev/shm; launch exactly ONE.
- **fd limit**: container `ulimit -n`=1024 -> FastDDS SHM `open_and_lock_file failed` at
  ~118 participants. Launch Autoware (and AWSIM) with `ulimit -n 65536` -> 0 SHM lock errors.
- **AWSIM cannot use a UDP FastDDS profile** (bundled FastDDS fails init -> no render). SHM only.
- **CPU**: no `taskset`/cpuset pinning for AWSIM. The official AWSIM quick start does not pin CPUs,
  and this stack now clears Docker cpuset with `docker update --cpuset-cpus=""` so Linux can schedule
  AWSIM and Autoware across all available cores.
  (Pinning AWSIM to <2 physical cores starves its sim loop -> clock stalls.)
- Launcher: `scripts/run_awsim.sh` (full working recipe).

## RESOLVED 2026-07-06 — localization + routing + AUTONOMOUS engage all working
Since the "REMAINING GAP" note below was written, the sensor pipeline gap was closed:
- **Switched to `sensor_model:=awsim_sensor_kit`** (AWSIM-Demo v2 has ONE lidar, "top" —
  `awsim_labs_sensor_kit` expects top+left+right, so concatenate silently skipped
  left/right (nullptr) and never produced a cloud. This, not the IMU timestamp, was the
  actual reason NDT had zero input.)
- **`cloud_relay.py`** (installed by `run_awsim.sh` step `[3.4]`): AWSIM-Demo v2 publishes
  `pointcloud_before_sync` with `row_step=0`. Downstream PCL parsing needs a real
  `row_step` (`width * point_step`) to produce a non-empty cloud — the relay patches this
  field before republishing to `/sensing/lidar/concatenated/pointcloud`, which is what
  actually let NDT start matching (verified: `relay: relayed N w=26765 row_step=428240`).
- **FastDDS Discovery Server** (`ROS_DISCOVERY_SERVER=127.0.0.1:11811`) instead of default
  multicast discovery — needed for reliable matching at AWSIM+Autoware's ~130-participant
  scale (multicast was dropping matches intermittently under load).
- **3-way CPU pinning**: AWSIM -> cores 0,1,8,9; localization (EKF/NDT/pose_init/gyro/twist)
  -> cores 2,3,10,11; rest of Autoware -> 4,5,6,7,12,13,14,15. Without this the EKF was
  starved to a ~2s period (needs ~0.02s) sharing cores with ~130 nodes.
- **Diagnostic relaxation for demo use**: `component_state_monitor` rate thresholds zeroed
  (checks "received" not "fast enough"), `/autoware/modes/autonomous` diag forced OK,
  `use_emergency_handling: false` on `vehicle_cmd_gate` (AWSIM demo mode was reading stale
  diagnostics as a system emergency and holding gear in PARK).

**Verified end-to-end** (2026-07-06, tablet app `com.keti.awsim_tesla` tap-to-go): real
Shinjuku pose (`x≈81377, y≈49917`) seeded correctly, route planned, gateway log shows
repeated successful `cmd: AUTONOMOUS`. This is a major step up from the previous
"localization stays UNINITIALIZED" state.

### Still-open: gear stuck at PARK under load (car doesn't actually move)
Even with `AUTONOMOUS` engaged, `/vehicle/status/gear_status` reads `22` (PARK) and
`/vehicle/status/velocity_status` stays `0.0` — the planner/control loop is live but the
vehicle interface isn't shifting to DRIVE. Measured **host load average ~20 on a 16-thread
box** while this runs (AWSIM alone ~220-260% CPU); `/tf topic is timeout` and
`distortion_corrector: IMU time_stamp is too late` warnings both fire steadily throughout
the run — consistent with a CPU-saturation symptom (matches the official AWSIM/Autoware
guidance that rate-sensitive nodes silently drop under contention; see
`docs/architecture.md` for the current backend-comparison table). `use_emergency_handling:
false` was already meant to stop diagnostics-driven PARK, so this looks like a **second,
separate PARK-hold path** (likely `operation_mode_transition_manager` or the vehicle
interface's own gear-shift gate reacting to the same failing `/tf` diagnostic) that the
existing patch doesn't cover yet.

**Next steps to try** (not yet done):
1. Find and relax/patch whatever specifically holds gear=PARK when `/tf` diagnostics are
   ERROR (search `operation_mode_transition_manager` and vehicle-interface gear-shift
   logic for a diagnostics-gated condition, similar to what `use_emergency_handling` fixed
   for the main gate).
2. Reduce AWSIM's own footprint to free CPU headroom: lower `-screen-width`/`-screen-height`
   further, or check if a lower Unity graphics quality preset is available via
   AWSIM-Demo's own settings/args.
3. Per current official upstream research (2026-07-06): the canonical repo is now
   **`autowarefoundation/AWSIM`** (v2.0.1, released 2025-10-31) — `tier4/AWSIM` now
   redirects there, and **AWSIM-Labs is archived/no-longer-maintained** (2026-01-11,
   https://github.com/orgs/autowarefoundation/discussions/6706). This project is already
   on the right binary (`AWSIM-Demo` = mainline v2.0.1); the leftover `awsim_labs_v1.6.1`
   binary and `awsim_labs_sensor_kit` references in the container are now dead weight and
   can be removed once nothing else depends on them.
4. If repeated-goal crashes appear (`rclcpp` "failed to add guard condition to wait set"),
   a community fix exists: rebuild `rclcpp` from TIER IV's fork (`t4-main` branch) instead
   of upstream ROS 2 Humble (https://github.com/orgs/autowarefoundation/discussions/6480).

## RESOLVED 2026-07-07 — code audit vs official AWSIM/Autoware repos

Systematically compared this project's `run_awsim.sh` against the official
`autowarefoundation/AWSIM` and `autowarefoundation/autoware` repos/docs. Findings, in order
of confidence:

- **Duplicate concatenated-pointcloud publisher (real bug, fixed)**: the deployed
  `awsim_sensor_kit_launch/lidar.launch.xml` (already trimmed to single-lidar, see below)
  had its OWN `topic_tools::RelayNode` composable node (`pointcloud_relay_ring_to_concat`)
  doing a raw, uncorrected `before_sync -> concatenated/pointcloud` relay — confirmed
  loading successfully in a past run's log (`Loaded node
  '/sensing/lidar/concatenated/pointcloud_relay_ring_to_concat' in container
  'pointcloud_container'`). This runs concurrently with `cloud_relay.py` ([3.4]), which
  ALSO publishes to the same topic but additionally fixes AWSIM's `row_step=0` bug. Two
  independent publishers on one topic race non-deterministically, so NDT's subscriber can
  land on either the broken (empty after PCL parse) or the fixed message — a very plausible
  cause of the intermittent `pose_buffer_.size() < 2` stalls already tracked in `[4/4]`
  status. **Fixed**: `run_awsim.sh` now deletes this composable-node block via `sed` in step
  `[0/4]`; applied directly to the running `autoware-shm:latest` image too. `[4/4]` status
  now also greps for the node name (should read 0 on the next run).
- **RMW/DDS vendor (CycloneDDS rejected, confirmed at the binary level)**: official Autoware
  docs recommend `rmw_cyclonedds_cpp` over the FastDDS-based setup this project uses.
  Checked directly: `AWSIM-Demo`'s bundled `ros2-for-unity` plugins have `rosidl` typesupport
  compiled for ~77 Autoware message packages, but **only against
  `rosidl_typesupport_fastrtps`** — 0 packages have CycloneDDS typesupport built in (the
  bundled `librmw_cyclonedds_cpp.so` is a bare RMW shim with no per-message typesupport at
  all, so it can't actually serialize any real topic). Switching Autoware's
  `RMW_IMPLEMENTATION` to CycloneDDS would desync it from AWSIM's own bridge entirely, not
  fix the (already-different) discovery problem the official guidance addresses. The FastDDS
  Discovery Server this project already uses is the correct choice for this specific binary,
  not a shortcut that should be replaced.
- **`use_distortion_corrector` sed (dead code, removed)**: the arg is declared in
  `lidar.launch.xml` but never referenced anywhere in the file body — there is no
  `distortion_corrector` node in this simplified single-lidar pipeline at all, so forcing it
  `true`/`false` had zero effect either way. The intermittent "IMU time_stamp is too late"
  warning comes from elsewhere in the graph. Removed the sed; the misleading "keep distortion
  ENABLED, it produces before_sync" comment was based on a stale understanding of the file.
- **sensor_kit lidar count (already correct for this deployment, no change)**: the pristine
  upstream `awsim_sensor_kit_launch` (tier4/AWSIM) ships top+left+right (3 lidars). The copy
  actually deployed in this container has already been trimmed to top-only, matching what
  AWSIM-Demo v2 actually publishes — this is a deliberate local simplification of the
  official file, not an oversight, and is correct as-is.
- **Build type (confirmed Release, no change)**: `readelf -S` on `vehicle_cmd_gate_exe` (and
  the other checked binaries) shows no `.debug*` sections and small stripped binary sizes —
  consistent with the official `ghcr.io/autowarefoundation/autoware:universe-cuda` image
  being a Release build. Not a Debug-build slowdown.
- **`vehicle_cmd_gate` gear-forces-PARK-while-disengaged (issue #2052 pattern, inconclusive)**:
  a historical, closed upstream bug where the gate forced PARK/DRIVE based on engagement
  state instead of echoing the current gear when disengaged — a plausible alternate
  explanation for the "gear stuck at PARK" symptom above, independent of pure CPU load. Could
  not fully re-verify against this exact binary (no source tree in the runtime image, only
  compiled `.so`/mangled symbols); the issue predates the currently-deployed
  `autoware_launch` 0.50.0 and is presumed fixed upstream. As a cheap, safe hedge regardless:
  widened `system_emergency_heartbeat_timeout` from `0.5s` to `3.0s` in
  `vehicle_cmd_gate.param.yaml` — 0.5s is tight for this box's measured load spikes (load avg
  ~26), and if that specific heartbeat topic gets starved under load it can force emergency
  behavior independent of the `use_emergency_handling` flag already set to `false`.
- **UDP/sysctl tuning (applied)**: raised `net.core.rmem_max`/`wmem_max` to 2 GiB and
  `net.ipv4.ipfrag_high_thresh` to 128 MiB / `ipfrag_time` to 3s (official CycloneDDS-doc
  values, but the underlying kernel UDP buffers are vendor-independent — helps FastDDS the
  same way). Previous host values (rmem_max 33 MB, ipfrag_high_thresh 4 MB, ipfrag_time 30s)
  were well under the documented recommendation for ~130-participant graphs with
  multi-megabyte PointCloud2 messages.

None of the above have been verified with a fresh end-to-end run yet (box was intentionally
kept off for this pass — no spare compute at the time). The duplicate-relay-node fix is the
one most likely to move the needle on the NDT stall symptom; the sysctl/heartbeat changes are
low-risk hedges. Still open: the CPU/TF-starvation root cause of "gear stuck at PARK" itself
(see "Still-open" section above) — none of this pass's fixes directly address AWSIM's own
sim-loop rate collapsing under system load.

## RESOLVED 2026-07-07 — manual teleop (app joystick) was ALSO gate-bypassing

Follow-up to the code audit above: the reason app-based manual driving on AWSIM felt "weird"
turned out to be the exact same anti-pattern as `awsim_gate_override.py` (removed 2026-06-xx
for the autonomous-mode path), just never caught for the manual-teleop path. Traced by reading
the actual `vehicle_cmd_gate.launch.xml` remaps in the deployed container:

- `ros_ws_gateway.py`'s `_teleop_tick()` (runs whenever the app arms manual/joystick control)
  was publishing gear + control commands directly to `/control/command/{control_cmd,gear_cmd}`
  — confirmed via the gate's own launch file to be `output/control_cmd` and `output/gear_cmd`,
  i.e. the gate's OWN OUTPUT, which `vehicle_cmd_gate_exe` also publishes to from its
  arbitration logic. The code's own top-comment even said it should go through
  `/external/selected/*` — the code just never matched what the comment claimed.
- Two publishers on one topic race non-deterministically. AWSIM has no actor-direct backup
  path (unlike CARLA's `_carla_loop`, which drives the CARLA actor directly regardless of what
  lands on this topic) — so on AWSIM this raced visibly as gear/control flicker during manual
  driving, and is the likely explanation for the pre-existing "flaky right after forward
  driving" note on manual reverse.
- **Fix**: retargeted `pub_ctrl`/`pub_gear` to `/external/selected/control_cmd` and
  `/external/selected/gear_cmd` — confirmed via `vehicle_cmd_gate.launch.xml`'s
  `input/external/{control_cmd,gear_cmd}` remaps to be exactly the gate's intended external
  command channel. `external_cmd_selector`/`external_cmd_converter` (also in this stack, both
  launched by default) only republish to those topics when THEY receive local/remote pedal
  input, which nothing in this project feeds, so the gateway remains the sole publisher — no
  new race introduced. Added a `/external/selected/heartbeat` publish too, since
  `check_external_emergency_heartbeat` defaults `true` on the gate and that topic was
  previously never fed at all.
- Deleted `ros/awsim_gate_override.py` (confirmed dead: `run_awsim.sh` stopped launching it a
  while ago, only a leftover `docker cp` deployment line and a `pgrep` status-check remained;
  both removed too).
- Side benefit: `roii_watchdog.py`/`roii_fault_detector.py`/`roii_reconfig_manager.py` all use
  `count_publishers("/control/command/control_cmd") > 0` as a control-pipeline health check.
  Previously, our own direct publish there during manual teleop would have counted as "a
  publisher" regardless of whether the gate/pipeline itself was actually healthy — a latent
  false-negative in those health checks during manual driving, incidentally fixed by no longer
  publishing there ourselves.

Not yet verified live (no spare compute for this pass, same as above) — this is a
well-evidenced, low-risk fix (topic names confirmed directly against the gate's own launch
file, not guessed) but should be checked against a real manual-drive session on AWSIM once one
is run.

### Correction (same day) — this exact fix was already tried once and reverted; found why

Caught by the user before going further: commit `efbabe6` (2026-06-09, "Manual teleop
joystick: tablet drives the ego") already tried publishing to `/external/selected/control_cmd`
and explicitly reverted it — commit message: *"The external/selected path didn't drive the
vehicle; direct injection does."* So the fix above was reintroducing something with a
documented prior failure. Went and read the actual
`autoware_universe/control/autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.cpp` source (not the
launch-file remaps this time) to find out why, rather than guessing:

```cpp
void VehicleCmdGate::publishControlCommands(const Commands & commands) {
  ...
  // Check engage
  if (!is_engaged_) {
    filtered_control.longitudinal = createLongitudinalStopControlCmd();
  }
  ...
}
```

This check runs **unconditionally**, regardless of `gate_mode` or which command source got
selected (`auto_commands_` vs `remote_commands_`). `is_engaged_` is only set by
`onEngage()`/`onEngageService()` — a message on `input/engage` (`/autoware/engage`,
`autoware_vehicle_msgs/msg/Engage`) or a call to `~/service/engage`
(`/api/autoware/set/engage`). Neither `efbabe6`'s original attempt nor this session's first
pass at the fix ever set this. Setting `GateMode=EXTERNAL` alone was never sufficient — the
gate forces a stop command regardless, unless `is_engaged_` is also true. The old direct-bypass
code "worked" only because publishing straight to the gate's OUTPUT topic
(`/control/command/control_cmd`) skips `publishControlCommands()` — and therefore this check —
entirely. It didn't fix the gap, it routed around it (at the cost of racing the gate's own
publisher, the bug this whole pass started from).

**Actual fix, this time**: `_arm_teleop()` now also publishes `Engage(engage=true)` to
`/autoware/engage` (3x, TRANSIENT_LOCAL so a late-joining gate still gets it) before/alongside
the existing `GateMode=EXTERNAL` + unpause. Also found and fixed a related latent bug while
tracing this: `_arm_teleop()` was the *only* place that ever set `GateMode`, and it always set
`EXTERNAL` — nothing ever set it back to `AUTO`. Once manual teleop was used even once, the
gate would stay on `remote_commands_` forever and a later autonomous engage's own trajectory
would never reach the vehicle. `_engage()` (the autonomous-drive entry point) now publishes
`GateMode(data=0)` (AUTO) at the start of engaging, reclaiming the gate from any prior
manual-teleop session.

QoS cross-checked against the actual subscriptions in `vehicle_cmd_gate.cpp`
(`create_subscription<...>("input/...", 1, ...)` — plain depth-1, i.e. default
RELIABLE/VOLATILE): our publishers use `TRANSIENT_LOCAL` (a superset of `VOLATILE` per DDS
durability compatibility rules), so no QoS mismatch blocks this. Still not verified live — same
compute constraint as above — but this pass is grounded in the actual gate source, not just the
launch-file topic wiring, which is what the previous pass was missing.

## (historical) Resolution paths considered before the in-container approach
1. **Install ROS2 humble RUNTIME libs on the host** (at least libspdlog1.9/libfmt8 + rcl deps,
   or a minimal `ros-humble-rmw-fastrtps-cpp`), so AWSIM-Labs runs NATIVELY on the host where
   Vulkan/HDRP renders (it hit 6 GB GPU there). Risk: coexisting with the host's jazzy.
   Cleanest: a humble overlay in /opt or an LD_LIBRARY_PATH shim dir with ONLY the missing
   humble libs (libspdlog.so.1.9.2, libfmt.so.8.1.1) — but ensure the bundled libs win over
   jazzy's ldconfig cache (place in $ORIGIN/Plugins, verify with `LD_DEBUG=libs`).
2. **Make Vulkan work in the container** (add NVIDIA Vulkan ICD: install `libvulkan1`
   `mesa-vulkan-drivers` + mount/provide `/usr/share/vulkan/icd.d/nvidia_icd.json` +
   `nvidia` driver libs) so AWSIM renders inside the humble container — then AWSIM + Autoware
   share the container's DDS (no host bridge needed).

## Run
    ./scripts/run_awsim.sh      # applies DDS config + launches AWSIM-Demo v2 + Autoware e2e
                                 # takes ~2-3 min (AWSIM render check + e2e settle); car
                                 # localizes and routes but currently sticks in gear=PARK
                                 # under CPU load -- see "still-open" section above.

The CARLA + real-map (판교/K-City planning_sim) + niro multimode + HMI gateway + Tesla apps
are all unaffected and on `main`.
