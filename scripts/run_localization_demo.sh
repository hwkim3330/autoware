#!/bin/bash
# ============================================================================
# WORKING single-box recipe: CARLA 0.9.16 + Autoware localization, side by side
# on one 16-core / RTX-3090 box.  This is the configuration that finally made
# the sensing -> NDT -> localization pipeline converge without CARLA crashing.
#
# The four fixes that made it work (see docs/autoware_carla_integration.md):
#   1. CPU partition   - CARLA pinned to cores 0-5, Autoware container to 6-15,
#                        so the Autoware start-up burst (load ~40) cannot starve
#                        CARLA's RPC server.
#   2. UDP-only DDS     - config/fastdds_udp.xml disables SHM transport; kills the
#                        fastrtps_port7411 lock that blocked ros2 CLI diagnostics.
#   3. Lidar-only kit   - config/sensor_mapping_lidar_only.yaml; 6 cameras made
#                        CARLA segfault on sensor-attach. Localization needs only
#                        LiDAR + IMU + GNSS.
#   4. Boot CARLA first - CARLA boots Town10HD, the interface's load_world(Town01)
#                        is a fast (~3 s) reload on a healthy server. CARLA boot is
#                        flaky (intermittent Signal 11 on UE4.26 / driver 535) -
#                        retry until the RPC port stays up.
#
# Verified: lidar 7.7 Hz, concatenated 9.9 Hz, NDT downsample 9.8 Hz,
#           kinematic_state 19 Hz, TF map->base_link present (converged).
# ============================================================================
set -u
TOWN="${1:-Town01}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CARLA_DIR=/opt/carla-simulator/CarlaUE4/Binaries/Linux
SUDO() { echo 1 | sudo -S "$@"; }

# --- display (CARLA needs a live X server even with -RenderOffScreen / Vulkan) -
GS=$(pgrep -x gnome-shell | head -1)
DISP=$(tr '\0' '\n' </proc/$GS/environ | grep '^DISPLAY=' | cut -d= -f2)
XA=$(tr '\0' '\n' </proc/$GS/environ | grep '^XAUTHORITY=' | cut -d= -f2)
: "${DISP:=:1}"; : "${XA:=/run/user/1000/gdm/Xauthority}"

echo "==> [1/5] Boot CARLA on cores 0-5 (retry until RPC stays up)"
SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
for attempt in 1 2 3 4 5; do
  cd "$CARLA_DIR"
  setsid taskset -c 0-5 env DISPLAY="$DISP" XAUTHORITY="$XA" \
    ./CarlaUE4-Linux-Shipping CarlaUE4 -RenderOffScreen -quality-level=Low \
    -nosound -carla-rpc-port=2000 </dev/null >/tmp/carla.log 2>&1 & disown
  up=0; for i in $(seq 1 25); do sleep 3; ss -tlnp 2>/dev/null | grep -q :2000 && { up=1; break; }; done
  if [ $up -eq 1 ]; then sleep 15; ss -tlnp 2>/dev/null | grep -q :2000 && { echo "    CARLA up (attempt $attempt)"; break; }; fi
  echo "    boot crashed, retrying ($attempt)"; SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
done
ss -tlnp 2>/dev/null | grep -q :2000 || { echo "CARLA failed to boot"; exit 1; }
SUDO renice -n -10 -p "$(pgrep -f CarlaUE4-Linux-Shipping | head -1)" >/dev/null 2>&1

echo "==> [2/5] Pin Autoware container to cores 6-15, install configs"
SUDO docker update --cpuset-cpus="6-15" autoware >/dev/null 2>&1
SUDO docker cp "$REPO/config/fastdds_udp.xml" autoware:/tmp/udp.xml >/dev/null 2>&1
SUDO docker cp "$REPO/config/sensor_mapping_lidar_only.yaml" \
  autoware:/opt/autoware/share/autoware_carla_interface/config/sensor_mapping.yaml >/dev/null 2>&1

echo "==> [3/5] Clear stale ROS processes (full container restart)"
SUDO docker restart autoware >/dev/null 2>&1; sleep 6

echo "==> [4/5] Launch Autoware e2e (localization only, UDP DDS)"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash && \
   ros2 launch autoware_launch e2e_simulator.launch.xml \
   map_path:=/root/autoware_map/$TOWN vehicle_model:=sample_vehicle \
   sensor_model:=carla_sensor_kit simulator_type:=carla carla_map:=$TOWN \
   timeout:=120 perception:=false rviz:=false launch_system_monitor:=false \
   > /tmp/e2e.log 2>&1"

echo "==> [5/5] Waiting for localization to converge (~90 s)..."
sleep 90
SUDO docker exec autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
   echo -n 'lidar before_sync : '; timeout 8 ros2 topic hz /sensing/lidar/top/pointcloud_before_sync 2>/dev/null|grep -m1 average; \
   echo -n 'NDT downsample in : '; timeout 8 ros2 topic hz /localization/util/downsample/pointcloud 2>/dev/null|grep -m1 average; \
   echo -n 'kinematic_state   : '; timeout 8 ros2 topic hz /localization/kinematic_state 2>/dev/null|grep -m1 average; \
   echo -n 'TF map->base_link : '; timeout 8 ros2 run tf2_ros tf2_echo map base_link 2>/dev/null|grep -m1 Translation"
echo "Done. CARLA log: /tmp/carla.log   Autoware log: docker exec autoware tail -f /tmp/e2e.log"
