#!/bin/bash
# ============================================================================
# REAL-MAP autonomous driving — Autoware planning simulator (no CARLA).
#
# Drives the SAME gateway + tablet app (tap-to-go) on a real-world lanelet2
# map. The planning simulator replaces CARLA+NDT: it integrates the vehicle
# kinematics itself and provides perfect localization + dummy perception, so
# any real location works with just a lanelet2 map (pcd optional).
#
#   bash scripts/run_real_map_sim.sh                      # sample real map
#   bash scripts/run_real_map_sim.sh /root/autoware_map/<your-map>
#
# Map dir must contain lanelet2_map.osm (+ map_projector_info.yaml).
# To make a KETI-area map: tools.tier4.jp Vector Map Builder -> export both.
# ============================================================================
set -u
MAP="${1:-/root/autoware_map/sample-map-planning}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUDO() { echo 1 | sudo -S "$@"; }

GS=$(pgrep -x gnome-shell | head -1)
DISP=$(tr '\0' '\n' </proc/$GS/environ 2>/dev/null | grep '^DISPLAY=' | cut -d= -f2)
XA=$(tr '\0' '\n' </proc/$GS/environ 2>/dev/null | grep '^XAUTHORITY=' | cut -d= -f2)
: "${DISP:=:1}"; : "${XA:=/run/user/1000/gdm/Xauthority}"

echo "==> [1/4] Reset container, install configs (map: $MAP)"
SUDO docker restart autoware >/dev/null 2>&1; sleep 6
SUDO docker cp "$REPO/config/fastdds_udp.xml" autoware:/tmp/udp.xml >/dev/null 2>&1
SUDO docker cp "$REPO/ros/ros_ws_gateway.py" autoware:/root/ros_ws_gateway.py >/dev/null 2>&1
SUDO docker cp "$REPO/container_patches/roii_clean.rviz" autoware:/root/roii_clean.rviz >/dev/null 2>&1
SUDO docker exec autoware bash -lc \
  "sed -i 's/max_vel: 4.17/max_vel: 8.33/' \
   /opt/autoware/share/autoware_launch/config/planning/scenario_planning/common/common.param.yaml" >/dev/null 2>&1
SUDO sysctl -w net.core.rmem_max=33554432 net.core.wmem_max=33554432 >/dev/null 2>&1 || true

echo "==> [2/4] Launch planning simulator"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash && \
   ros2 launch autoware_launch planning_simulator.launch.xml \
   map_path:=$MAP vehicle_model:=sample_vehicle sensor_model:=sample_sensor_kit \
   rviz:=false > /tmp/psim.log 2>&1"
sleep 45

echo "==> [3/4] Initial pose on a lane (find_spawn on the map osm)"
# find an aligned on-lane pose from the osm and publish it as /initialpose
SUDO docker cp "$REPO/ros/find_spawn.py" autoware:/root/find_spawn.py >/dev/null 2>&1
SUDO docker exec autoware bash -lc "
export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash
SP=\$(python3 /root/find_spawn.py $MAP/lanelet2_map.osm | grep 'Autoware on-lane' | grep -oE '\(-?[0-9.]+, -?[0-9.]+, -?[0-9.]+deg\)')
X=\$(echo \$SP | tr -d '()deg' | cut -d, -f1); Y=\$(echo \$SP | tr -d '()deg' | cut -d, -f2); YAW=\$(echo \$SP | tr -d '()deg' | cut -d, -f3)
QZ=\$(python3 -c \"import math;print(math.sin(math.radians(\$YAW)/2))\")
QW=\$(python3 -c \"import math;print(math.cos(math.radians(\$YAW)/2))\")
echo \"initialpose: x=\$X y=\$Y yaw=\$YAW\"
ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
\"{header: {frame_id: map}, pose: {pose: {position: {x: \$X, y: \$Y, z: 0.0}, orientation: {z: \$QZ, w: \$QW}}, covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.068]}}\" >/dev/null"

echo "==> [4/4] Gateway + rviz"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export LANELET_OSM=$MAP/lanelet2_map.osm; \
   source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1 || true
DISPLAY=$DISP XAUTHORITY=$XA xhost +local: >/dev/null 2>&1 || true
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export DISPLAY=$DISP; export XAUTHORITY=/root/.Xauthority; \
   source /opt/autoware/setup.bash; rviz2 -d /root/roii_clean.rviz > /tmp/rviz.log 2>&1"
echo "Done. Tablet: DRIVE or tap the map. (planning sim: perfect localization, no CARLA)"
exit 0
