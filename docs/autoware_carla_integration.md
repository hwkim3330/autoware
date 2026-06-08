# Autoware ↔ CARLA integration plan (chosen path)

## Decision
Run the **officially supported combo** for a real Autoware closed loop:

- **NVIDIA driver 535** (downgraded from 580 — UE4.26 / CARLA 0.9.x hangs the
  render thread on driver 580; 535 is the tested era and fully supports RTX 3090).
  Docker shares the **host** driver, so the host must be 535 even for dockerized CARLA.
- **CARLA 0.9.16** (`carlasim/carla:0.9.16` docker, or the native install at
  `/opt/carla-simulator`).
- **Autoware** via `ghcr.io/autowarefoundation/autoware:universe-cuda` (ROS 2 Humble,
  prebuilt). The image already ships **`autoware_carla_interface`**,
  `carla_sensor_kit_launch`, `carla_sensor_kit_description`.

Why not CARLA 0.10.0: the bundled `autoware_carla_interface` is written for CARLA
0.9.x, has no 0.10 support and no bundled Town maps → 0.10.0 would be undocumented glue.
0.10.0 (UE5) DOES run on driver 580 (see docs/carla_live_setup.md) and is what the
live tablet demo used, but it is not the path for Autoware.

## Components found in the Autoware image
- `/opt/autoware` prebuilt, ROS humble (python3.10)
- `autoware_carla_interface` launch: `autoware_carla_interface.launch.xml`
  defaults: host=localhost port=2000 carla_map=Town01 vehicle=vehicle.toyota.prius
  sync_mode=True fixed_delta_seconds=0.05, sensor_kit=carla_sensor_kit_description
- `import carla` is NOT installed in the image → must `pip install carla==<server ver>`
  inside the container (client/server versions must match).
- No CARLA lanelet2/pcd maps bundled → get from the `carla_autoware` / TIER IV map repos.

## Steps
1. `sudo apt install nvidia-driver-535` → **reboot** (host driver 535).
2. `docker pull carlasim/carla:0.9.16`.
3. Run CARLA: `docker run --rm --gpus all --net host carlasim/carla:0.9.16 \
   ./CarlaUE4.sh -RenderOffScreen -nosound -quality-level=Epic` (docker image is
   built for headless GPU — avoids the host X-session hassle).
4. Run Autoware container (`--gpus all --net host`, X mounted for rviz), inside:
   `pip install carla==0.9.16`, place the Town01 map under the autoware map dir,
   `ros2 launch autoware_carla_interface autoware_carla_interface.launch.xml`.
5. Then `ros2 launch autoware_launch autoware.launch.xml map_path:=...` to bring up
   the full stack; set a goal in rviz to drive the CARLA ego.
6. Tablet app: the existing `ros/carla_ws_gateway.py` (or a ROS2→WS bridge) feeds the
   localization-multimode view — app unchanged (version-agnostic WebSocket contract).

## Status
- [x] Docker + nvidia-container-toolkit (GPU-in-docker verified: RTX 3090)
- [x] Autoware image pulled (`universe-cuda`, 20.4GB) with carla interface
- [x] **nvidia-driver-535 installed (535.309.01); 580 removed — REBOOT required**
      (pre-reboot `nvidia-smi` shows "Driver/library version mismatch" — expected;
      the running kernel module is still 580 until reboot)
- [x] CARLA 0.9.16 docker image pulled (`carlasim/carla:0.9.16`)
- [x] reboot done → driver 535 active; native CARLA 0.9.16 renders on RTX 3090 (6.8GB VRAM, world ready Town10HD). Docker CARLA image too old (U18.04 Vulkan loader) for 535 ICD → use NATIVE 0.9.16.
- [x] **autoware_carla_interface LIVE**: native CARLA 0.9.16 -> Autoware container (--net host). Ego spawns with Autoware sensor kit; /sensing/{lidar(6.9Hz),gnss,imu,camera x6}, /control/command/control_cmd all flowing. carla==0.9.16 pip-installed in container.
- [ ] full autonomy stack (lanelet2+pcd Town map) + rviz goal -> closed-loop control
- [ ] closed loop + tablet app (ros/carla_ws_gateway.py)

### Confirmed by web search (driver direction)
CARLA 0.9.x (UE4.26 / Vulkan) RenderThread-timeouts on NVIDIA **550/555/560+**
(incl. 580/6xx) are a known issue; `-prefernvidia` / `VK_ICD_FILENAMES` don't fix it,
`-opengl` is unavailable (Vulkan-only since 0.9.12). Newer driver = worse for UE4.26.
→ 535 (≈2023, supports RTX 3090) is the compatible target. Refs: carla issues
#8043, #8079, #9502, #1456.
