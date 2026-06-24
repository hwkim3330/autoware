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
# Relax the autonomous-availability diag gates (same as the CARLA path): the
# control_command / trajectory_follower monitors are a chicken-and-egg gate (the
# post-gate control_cmd only flows once engaged, but availability needs it), and
# the map->base_link transform monitor can wedge. The follower runs fine (33 Hz
# pre-gate); removing these leaves lets autonomous engage so control starts.
CY=/opt/autoware/share/autoware_launch/config/system/diagnostics/control.yaml
SUDO docker exec autoware bash -lc \
  "sed -i '/link: \/autoware\/control\/topic_rate_check\/trajectory_follower }/d; /link: \/autoware\/control\/topic_rate_check\/control_command }/d; /link: \/autoware\/control\/performance_monitoring\/lane_departure }/d; /link: \/autoware\/control\/performance_monitoring\/control_state }/d' $CY" >/dev/null 2>&1 || true
LY=/opt/autoware/share/autoware_launch/config/system/diagnostics/localization.yaml
# Remove the LINK references (not the leaf blocks) -- deleting a leaf block while a
# parent unit still links it makes the aggregator throw PathNotFound and DIE, which
# leaves availability=false forever. Removing the link line is the safe relaxation.
SUDO docker exec autoware bash -lc \
  "sed -i '/link: \/autoware\/localization\/accuracy }/d; /link: \/autoware\/localization\/sensor_fusion_status }/d; /link: \/autoware\/localization\/topic_rate_check\/transform }/d' $LY" >/dev/null 2>&1 || true
# THE engage gate: /autoware/modes/autonomous (autoware-main.yaml) requires
# /autoware/control, which can't be OK pre-engage (post-gate control_cmd only
# flows once autonomous -> chicken-and-egg). Drop the control requirement from the
# autonomous mode so it becomes available; the trajectory follower (33 Hz pre-gate)
# starts driving the moment we engage.
MY=/opt/autoware/share/autoware_launch/config/system/diagnostics/autoware-main.yaml
# planning_sim has dummy perception + no real vehicle/system feedback pre-engage,
# so reduce the autonomous requirement to the essentials for trajectory-following:
# map + localization + planning (all OK once localized with a route). This cuts the
# control/perception/vehicle/system/mrm chicken-and-egg gates in one go.
SUDO docker exec autoware bash -lc \
  "sed -i '/path: \/autoware\/modes\/autonomous/,/^  - path:/ {/link: \/autoware\/control }/d; /link: \/autoware\/perception }/d; /link: \/autoware\/vehicle }/d; /link: \/autoware\/system }/d; /mrm_request\/delegate }/d}' $MY" >/dev/null 2>&1 || true

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
# geo-origin so the tablet can show the ego on a real OpenStreetMap basemap
SITE=$(basename "$MAP")
# prefer a precise origin file written by the converter (NGII), else known sites
ORIGIN=""
OF=$(ls "$HOME/autoware_map/$SITE/"*.origin 2>/dev/null | head -1)
if [ -n "$OF" ]; then
  ORIGIN=$(awk '{print $1","$2}' "$OF")
else
  case "$SITE" in
    soongsil) ORIGIN="37.4963,126.9573" ;;
    pangyo)   ORIGIN="37.3947,127.1112" ;;
    kcity)    ORIGIN="37.2410,126.7720" ;;
  esac
fi
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export LANELET_OSM=$MAP/lanelet2_map.osm; \
   export NIRO_ORIGIN='$ORIGIN'; export NIRO_SITE='$SITE'; \
   source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=false > /tmp/gw.log 2>&1"
# ^ planning_simulator publishes NO /clock, so use_sim_time:=true FREEZES every ROS
#   timer in the gateway (incl. _process_cmds) -> no app command ever runs. Wall-clock
#   (false) makes timers fire normally. (CARLA path keeps use_sim_time:=true; it has /clock.)
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1 || true
DISPLAY=$DISP XAUTHORITY=$XA xhost +local: >/dev/null 2>&1 || true
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export DISPLAY=$DISP; export XAUTHORITY=/root/.Xauthority; \
   source /opt/autoware/setup.bash; rviz2 -d /root/roii_clean.rviz > /tmp/rviz.log 2>&1"
# real maps (NGII): re-seed the ego on a WELL-CONNECTED lanelet at road elevation,
# so tap-to-go / drive works right after a switch (find_spawn picks a stub).
case "$SITE" in
  pangyo*|kcity*|soongsil*)
    SUDO docker cp "$REPO/ros/seed_realmap_start.py" autoware:/root/seed_realmap_start.py >/dev/null 2>&1
    sleep 6
    SUDO docker exec autoware bash -lc \
      "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
       python3 /root/seed_realmap_start.py $SITE 2>/dev/null" 2>/dev/null | grep -E "seed|seeded" || true
    ;;
esac
echo "Done. Tablet: DRIVE or tap the map. (planning sim: perfect localization, no CARLA)"
exit 0
