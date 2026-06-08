# CARLA live setup (RTX 3090) + WebSocket gateway → tablet app

End-to-end verified live chain:
**CARLA 0.10.0 (RTX 3090) → `ros/carla_ws_gateway.py` → WebSocket → Flutter app (Galaxy Tab S7 FE)**

## Hardware / versions
- NVIDIA RTX 3090 (24GB), driver 580.159.03, 31GB RAM, Ubuntu 24.04, ROS 2 Jazzy.
- **CARLA 0.10.0 (UE5)** at `/opt/carla-0.10.0/Carla-0.10.0-Linux-Shipping` — works on driver 580.
- CARLA 0.9.16 (UE4.26) does **not** run on driver 580 (VulkanRHI render-thread hang / Signal 11),
  even with a desktop session. It needs an older driver (≈535). 0.9.16 has the more mature
  ecosystem (our `carla-ros-bridge` targets it), so if you downgrade the driver it becomes usable.

## Hard-won launch requirements (CARLA 0.10.0)
1. **Monitor must be plugged into the RTX 3090** (not the motherboard iGPU) and you must be
   **logged into a GNOME desktop (Xorg) session**. Without a real GPU desktop session the render
   thread hangs ("GameThread timed out waiting for RenderThread after 60s") or never starts.
   The session exposes `DISPLAY=:1`, `XAUTHORITY=/run/user/1000/gdm/Xauthority`.
2. **Launch the binary directly** (don't rely on a helper script — they got deleted in this env):
   ```bash
   cd /opt/carla-0.10.0/Carla-0.10.0-Linux-Shipping/CarlaUnreal/Binaries/Linux
   setsid env DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority \
     ./CarlaUnreal-Linux-Shipping CarlaUnreal -RenderOffScreen -nosound -carla-rpc-port=2000 \
     </dev/null >/tmp/carla.log 2>&1 & disown
   ```
   Up in ~5s: port 2000, ~76 threads, ~8GB VRAM. Verify:
   ```bash
   python3 -c "import carla; c=carla.Client('localhost',2000); c.set_timeout(40); print(c.get_world().get_map().name)"
   ```
3. When checking if it's running, match the **binary path**, never `pgrep -f CarlaUnreal-Linux-Shipping`
   (that matches your own monitoring commands).

## Gateway → app
```bash
pip install --break-system-packages websockets \
  /opt/carla-0.10.0/Carla-0.10.0-Linux-Shipping/PythonAPI/carla/dist/carla-0.10.0-cp312-cp312-linux_x86_64.whl
python3 ros/carla_ws_gateway.py          # spawns autopilot ego, serves ws://0.0.0.0:8765/ws
adb reverse tcp:8765 tcp:8765            # tablet 127.0.0.1:8765 -> PC
```
The gateway publishes the app's data contract (docs/data_contract.md) 1 Hz with **live CARLA
telemetry** (map, ego position/speed, GNSS) and a localization-multimode overlay derived from
sensor health. Inject faults to drive mode transitions: `FAULT=gnss python3 ros/carla_ws_gateway.py`
(→ LiDAR+Camera fallback), `FAULT=lidar,gnss` (→ camera-only), etc.

In the app: Settings → Data Source = **USB_ADB** (or WIFI with the PC IP) → Connect. The dashboard
then shows `source=VEHICLE`, scenario "CARLA Live (autopilot)", live position/speed, and the
localization mode reacting to injected faults. (App default is DEMO; it auto-falls back to DEMO if
the gateway is unreachable.)

## Notes
- `mesa-vulkan-drivers` is held at 24.0.5 from the pre-GPU lavapipe era; can be un-held now
  (`sudo apt-mark unhold mesa-vulkan-drivers`) since a real GPU is present.
- A dedicated headless Xorg (`/etc/X11/xorg-carla.conf`, BusID PCI:1:0:0) exists as a fallback, but
  the logged-in GNOME session is what worked.
