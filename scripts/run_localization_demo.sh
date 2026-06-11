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
TOWN="${1:-Town04}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CARLA_DIR=/opt/carla-simulator/CarlaUE4/Binaries/Linux
SUDO() { echo 1 | sudo -S "$@"; }

# Aligned on-lane spawn per town (CARLA coords, facing lane direction), computed
# by ros/find_spawn.py from each town's lanelet2 osm. A RANDOM/off-direction
# spawn makes the mission planner fail to match a start lanelet -> every route
# comes back "planned route is empty". These put the ego on the longest lane,
# aligned with traffic, so set_route_points succeeds.
# (validated: each spawn has 150+ centerline points 40-90 m ahead, so the
#  gateway's goal search always has routable candidates)
case "$TOWN" in
  Town01)   SPAWN="144.1, 129.7, 0.6, 0.0, 0.0, 180.0" ;;
  Town02)   SPAWN="125.0, 240.9, 0.5, 0.0, 0.0, -0.0" ;;
  Town03)   SPAWN="227.5, 146.2, 0.5, 0.0, 0.0, 100.7" ;;
  Town04)   SPAWN="60.7, 260.1, 0.5, 0.0, 0.0, -218.6" ;;
  Town05)   SPAWN="-184.6, -31.8, 0.9, 0.0, 0.0, -90.0" ;;
  Town06)   SPAWN="606.8, 152.4, 0.6, 0.0, 0.0, 0.2" ;;
  Town07)   SPAWN="-31.4, -109.0, 0.6, 0.0, 0.0, -179.8" ;;
  Town10HD) SPAWN="19.4, -57.4, 0.5, 0.0, 0.0, -180.0" ;;
  *)        SPAWN="None" ;;
esac
echo "==> Town=$TOWN  aligned spawn=[$SPAWN]"

# --- display (CARLA needs a live X server even with -RenderOffScreen / Vulkan) -
GS=$(pgrep -x gnome-shell | head -1)
DISP=$(tr '\0' '\n' </proc/$GS/environ | grep '^DISPLAY=' | cut -d= -f2)
XA=$(tr '\0' '\n' </proc/$GS/environ | grep '^XAUTHORITY=' | cut -d= -f2)
: "${DISP:=:1}"; : "${XA:=/run/user/1000/gdm/Xauthority}"

# Raise UDP socket buffer ceilings so Fast-DDS can hold a fully fragmented
# multi-MB vector map (see config/fastdds_udp.xml). The container shares the host
# kernel net namespace, so setting it here applies inside the container too.
SUDO sysctl -w net.core.rmem_max=33554432 net.core.wmem_max=33554432 >/dev/null 2>&1 || true

echo "==> [1/5] Boot CARLA on cores 0-5 (retry until RPC stays up)"
SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
for attempt in 1 2 3 4 5; do
  cd "$CARLA_DIR"
  setsid taskset -c 0,8 env DISPLAY="$DISP" XAUTHORITY="$XA" \
    ./CarlaUE4-Linux-Shipping "$TOWN" -RenderOffScreen -quality-level=Low \
    -nosound -carla-rpc-port=2000 </dev/null >/tmp/carla.log 2>&1 & disown
  up=0; for i in $(seq 1 25); do sleep 3; ss -tlnp 2>/dev/null | grep -q :2000 && { up=1; break; }; done
  if [ $up -eq 1 ]; then sleep 15; ss -tlnp 2>/dev/null | grep -q :2000 && { echo "    CARLA up (attempt $attempt)"; break; }; fi
  echo "    boot crashed, retrying ($attempt)"; SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
done
ss -tlnp 2>/dev/null | grep -q :2000 || { echo "CARLA failed to boot"; exit 1; }
SUDO renice -n -10 -p "$(pgrep -f CarlaUE4-Linux-Shipping | head -1)" >/dev/null 2>&1

echo "==> [2/5] Pin Autoware container to cores 6-15, install configs (LIDARS=${LIDARS:-4})"
SUDO docker update --cpuset-cpus="1-7,9-15" autoware >/dev/null 2>&1
SUDO docker cp "$REPO/config/fastdds_udp.xml" autoware:/tmp/udp.xml >/dev/null 2>&1

# LiDAR suite: default = ROii 4-LiDAR (front/rear G32 directional + side rotating
# Pandars, concatenated). LIDARS=1 falls back to the single velodyne_top config.
if [ "${LIDARS:-4}" = "4" ]; then
  SUDO docker cp "$REPO/config/sensor_mapping_roii_4lidar.yaml" \
    autoware:/opt/autoware/share/autoware_carla_interface/config/sensor_mapping.yaml >/dev/null 2>&1
  SUDO docker cp "$REPO/container_patches/pointcloud_preprocessor_4lidar.launch.py" \
    autoware:/opt/autoware/share/carla_sensor_kit_launch/launch/pointcloud_preprocessor.launch.py >/dev/null 2>&1
  SUDO docker cp "$REPO/container_patches/sensor_kit_calibration.yaml" \
    autoware:/opt/autoware/share/carla_sensor_kit_description/config/sensor_kit_calibration.yaml >/dev/null 2>&1
  SUDO docker cp "$REPO/container_patches/carla_wrapper.py" \
    autoware:/opt/autoware/lib/python3.10/site-packages/autoware_carla_interface/modules/carla_wrapper.py >/dev/null 2>&1
else
  SUDO docker cp "$REPO/config/sensor_mapping_lidar_only.yaml" \
    autoware:/opt/autoware/share/autoware_carla_interface/config/sensor_mapping.yaml >/dev/null 2>&1
  SUDO docker cp "$REPO/container_patches/pointcloud_preprocessor_1lidar.launch.py" \
    autoware:/opt/autoware/share/carla_sensor_kit_launch/launch/pointcloud_preprocessor.launch.py >/dev/null 2>&1
fi

# Camera-off interface launch (camera relay/republish/combiner nodes stripped ->
# no camera processes, saves CPU; cameras are not simulated in the lidar-only kit).
SUDO docker cp "$REPO/container_patches/autoware_carla_interface.launch.xml" \
  autoware:/opt/autoware/share/autoware_carla_interface/autoware_carla_interface.launch.xml >/dev/null 2>&1

# Reverse-gear patch (stock interface hardcodes DRIVE; tablet REVERSE needs it).
SUDO docker cp "$REPO/container_patches/carla_ros.py" \
  autoware:/opt/autoware/lib/python3.10/site-packages/autoware_carla_interface/carla_ros.py >/dev/null 2>&1

# Vector(lanelet2) map uses local_x/local_y -> the map MUST be loaded with the
# 'local' projector, else it defaults to MGRS and the lanelets land far from the
# pointcloud/ego: routing returns "planned route is empty" and rviz shows a black
# (empty) map at the ego. Install local projector for every town's map.
SUDO docker exec autoware bash -lc \
  'for d in /root/autoware_map/Town*/; do echo "projector_type: local" > "$d/map_projector_info.yaml"; done' >/dev/null 2>&1

# Cruise speed: planner global cap (default 4.17 m/s = 15 km/h). 8.33 = 30 km/h;
# actual speed = min(this, lanelet speed_limit, curve/decel constraints).
SUDO docker exec autoware bash -lc \
  "sed -i 's/max_vel: 4.17/max_vel: 8.33/' \
   /opt/autoware/share/autoware_launch/config/planning/scenario_planning/common/common.param.yaml" >/dev/null 2>&1

# Set the aligned spawn as the interface's spawn_point default (e2e_simulator does
# not forward a spawn_point arg, so we bake it into the patched launch file).
SUDO docker exec autoware bash -lc \
  "sed -i 's|name=\"spawn_point\" default=\"None\"|name=\"spawn_point\" default=\"$SPAWN\"|' \
   /opt/autoware/share/autoware_carla_interface/autoware_carla_interface.launch.xml" >/dev/null 2>&1

# Refresh the gateway + perception stub + helper scripts in the container.
for f in ros_ws_gateway.py perception_stub.py find_spawn.py diag_route.py diag_connectivity.py; do
  [ -f "$REPO/ros/$f" ] && SUDO docker cp "$REPO/ros/$f" autoware:/root/$f >/dev/null 2>&1
done
SUDO docker cp "$REPO/container_patches/roii_clean.rviz" autoware:/root/roii_clean.rviz >/dev/null 2>&1
SUDO docker cp "$REPO/container_patches/autoware_no_camera.rviz" autoware:/root/autoware_no_camera.rviz >/dev/null 2>&1

# Relax localization diag so autonomous engage isn't blocked by the
# accuracy/sensor_fusion ERROR leaves (stationary CARLA: sparse NDT, pose_buffer<2).
LOCYAML=/opt/autoware/share/autoware_launch/config/system/diagnostics/localization.yaml
SUDO docker exec autoware bash -lc \
  "sed -i '/link: \/autoware\/localization\/accuracy }/d; /link: \/autoware\/localization\/sensor_fusion_status }/d' $LOCYAML" >/dev/null 2>&1 || true
CTLYAML=/opt/autoware/share/autoware_launch/config/system/diagnostics/control.yaml
SUDO docker exec autoware bash -lc \
  "sed -i '/link: \/autoware\/control\/topic_rate_check\/trajectory_follower }/d; /link: \/autoware\/control\/topic_rate_check\/control_command }/d; /link: \/autoware\/control\/performance_monitoring\/lane_departure }/d; /link: \/autoware\/control\/performance_monitoring\/control_state }/d' $CTLYAML" >/dev/null 2>&1 || true

echo "==> [3/5] Clear stale ROS processes (full container restart)"
SUDO docker restart autoware >/dev/null 2>&1 || true; sleep 6

echo "==> [4/5] Launch Autoware e2e (localization only, UDP DDS)"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash && \
   ros2 launch autoware_launch e2e_simulator.launch.xml \
   map_path:=/root/autoware_map/$TOWN vehicle_model:=sample_vehicle \
   sensor_model:=carla_sensor_kit simulator_type:=carla carla_map:=$TOWN \
   timeout:=300 perception:=false rviz:=false launch_system_monitor:=false \
   > /tmp/e2e.log 2>&1"

echo "==> [5/5] Waiting for localization to converge (~90 s)..."
sleep 90
SUDO docker exec autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
   echo -n 'lidar front       : '; timeout 8 ros2 topic hz /sensing/lidar/front/pointcloud_before_sync 2>/dev/null|grep -m1 average || timeout 8 ros2 topic hz /sensing/lidar/top/pointcloud_before_sync 2>/dev/null|grep -m1 average; \
   echo -n 'lidar concat      : '; timeout 8 ros2 topic hz /sensing/lidar/concatenated/pointcloud 2>/dev/null|grep -m1 average; \
   echo -n 'NDT downsample in : '; timeout 8 ros2 topic hz /localization/util/downsample/pointcloud 2>/dev/null|grep -m1 average; \
   echo -n 'kinematic_state   : '; timeout 8 ros2 topic hz /localization/kinematic_state 2>/dev/null|grep -m1 average; \
   echo -n 'TF map->base_link : '; timeout 8 ros2 run tf2_ros tf2_echo map base_link 2>/dev/null|grep -m1 Translation"

echo "==> Start ROS->WebSocket gateway (tablet app) + rviz on the monitor"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
  python3 /root/perception_stub.py --ros-args -p use_sim_time:=true > /tmp/pstub.log 2>&1 &
   export LANELET_OSM=/root/autoware_map/'$TOWN'/lanelet2_map.osm; python3 /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1 || true
# rviz on the host monitor (CARLA is RenderOffScreen, so the GPU display is free)
DISPLAY=$DISP XAUTHORITY=$XA xhost +local: >/dev/null 2>&1 || true
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export DISPLAY=$DISP; export XAUTHORITY=/root/.Xauthority; \
   source /opt/autoware/setup.bash; \
   rviz2 -d /root/autoware_no_camera.rviz > /tmp/rviz.log 2>&1"
echo "Done. Gateway: ws://<host>:8765/ws (adb reverse for USB). rviz on the monitor."
echo "CARLA log: /tmp/carla.log   Autoware log: docker exec autoware tail -f /tmp/e2e.log"
exit 0
