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
