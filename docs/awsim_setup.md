# AWSIM (Autoware Unity sim) — setup status & full diagnosis

Goal: replace MORAI with **AWSIM** for a real-area driving sim (Nishi-Shinjuku, Tokyo)
that gives live sensors (multi-LiDAR + camera + NPC vehicles) → Autoware → Tesla tablet
app, with OpenStreetMap (Shinjuku is fully in OSM).

## What's done / working
- **Binaries downloaded**: `~/AWSIM/AWSIM-Demo/` (autowarefoundation/AWSIM v2.0.1) and
  `~/AWSIM/awsim_labs/awsim_labs_v1.6.1/` (AWSIM-Labs v1.6.1 — matches the container's
  `awsim_labs_sensor_kit`/`awsim_labs_vehicle`, which is the RIGHT one).
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

## Resolution paths (pick one, focused session)
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

## Run (once a path above is done)
    ./scripts/run_awsim.sh      # applies DDS config + launches AWSIM-Labs + Autoware e2e

The CARLA + real-map (판교/K-City planning_sim) + niro multimode + HMI gateway + Tesla apps
are all unaffected and on `main`.
