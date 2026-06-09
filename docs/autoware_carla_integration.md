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

## STABILITY: unexpected reboot under load — root cause = `watchdog` daemon
Symptom: the box rebooted ~44 min into running CARLA + the full 181-node Autoware
stack. **Not hardware** — the journal showed a clean SIGTERM shutdown, no Xid/MCE/
thermal/OOM. Culprit (journalctl -b -1):
```
watchdog[]: loadavg 59 21 9 is higher than the given threshold 36 28 20!
watchdog[]: shutting down the system because of error 253 = 'load average too high'
systemd[1]: Received SIGTERM from PID  (watchdog).
```
The `watchdog` package was configured (`/etc/watchdog.conf`) with `max-load-1=36`
and reboots when load exceeds it. 16-core box, full Autoware legitimately hits
load ~59 → watchdog misreads it as a hang and reboots.
**Fix:** `sudo systemctl disable --now watchdog` and comment out the `max-load-*`
lines in `/etc/watchdog.conf`. Done on this host.

Also: `docker commit autoware autoware-ready` bakes the carla client + ~3.6GB ML
artifacts into a reusable image so a container loss doesn't require re-downloading.
`scripts/start_autoware.sh` defaults to the `autoware-ready` image.

## STABILITY 2: single-box overload — CARLA crashes under full Autoware
Symptom (the "rviz shows at first launch then goes black"): CARLA + the FULL
Autoware stack (193 nodes incl. GPU perception: centerpoint/bevdet/etc.) on ONE
16-core + RTX 3090 box saturates resources. Observed:
- `load average` spiked to **~51 on 16 cores** during Autoware perception startup.
- CARLA's RPC stalled >20s → `autoware_carla_interface` died with
  `RuntimeError: time-out of 20000ms ... waiting for the simulator`
  (in `ego_status()` / `get_wheel_steer_angle`), ego despawned, sensors stopped.
- Then CARLA itself **segfaulted (Signal 11)** under the GPU/CPU contention.

So it "works at first" (before perception fully loads) then everything stops.

Mitigations (in order):
1. **Raise the interface timeout** so it survives startup spikes:
   `/opt/autoware/share/autoware_carla_interface/autoware_carla_interface.launch.xml`
   `timeout` default 20 → 120 (also pass `timeout:=120` to e2e). Done.
2. **Run Autoware lighter** — drop the heavy GPU perception ML and run
   localization + planning + control only, so CARLA isn't starved.
3. CARLA `-quality-level=Low`, cap fps; pin CPUs; or split CARLA / Autoware
   across two machines (the production pattern).

Separate pipeline note: even when the interface is alive, the NDT input
`/localization/util/downsample/pointcloud` was empty (the carla_sensor_kit
concatenate→downsample chain didn't produce output for the single CARLA lidar),
so NDT couldn't converge (no map→base_link TF → black rviz). Needs sensor-kit
sensing-pipeline review in addition to the load fix.

## CONCLUSION: single 16-core box is the limit (split machines for closed loop)
After fixing the watchdog and lowering Autoware (perception:=false, rviz:=false),
the box STILL can't sustain CARLA + Autoware together:
- perception ON → load ~51 → CARLA segfaults.
- perception OFF → load ~21 (16 cores) → NDT sensing preprocessing can't keep up
  AND CARLA still dies under sustained contention; even `ros2 topic info` times out.
- rviz (in container) fails GLXContext creation while CARLA holds the GPU/display
  (container-GL vs host-driver + display contention) — floods logs.

What's solid (done, committed): CARLA 0.9.16 on RTX3090 (driver 535) renders;
Autoware universe-cuda image + autoware_carla_interface bring up the full stack;
the CARLA→Autoware sensor/control bridge is LIVE (sensors + control_cmd); all 8
town maps; interface timeout 20→120; ipc=host + shm for DDS; baked autoware-ready
image. The Flutter tablet app is version-agnostic via the WebSocket gateway.

Remaining for a closed loop (needs an unsaturated environment):
1. Sensing→NDT: `/localization/util/downsample/pointcloud` empty — verify the
   lidar frame_id ↔ carla_sensor_kit TF so the CropBox/relay feeds NDT.
2. rviz on a display not shared with CARLA (separate X / second machine), or
   visualize via the tablet app instead.
RECOMMENDED ARCHITECTURE: run CARLA and Autoware on TWO machines (the standard
CARLA-Autoware setup), or a much higher-core box, so neither starves the other.
