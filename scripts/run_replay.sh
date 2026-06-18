#!/bin/bash
# One-click ROS2 bag replay for the tablet + rviz.
#   ./run.sh replay [bag_dir] [town]
# Plays a recorded bag (looped) and runs the ROS<->WS gateway + rviz so the
# tablet app shows the recorded run (ego on the map, trajectory, objects).
# No CARLA / no live Autoware -- just the bag publishing + the gateway reading it.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BAG="${1:-/root/replay/recorded}"          # path INSIDE the container
TOWN="${2:-Town04}"
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }

GS=$(pgrep -x gnome-shell | head -1)
DISP=$(tr '\0' '\n' </proc/$GS/environ 2>/dev/null | grep '^DISPLAY=' | cut -d= -f2); : "${DISP:=:1}"

echo "==> [replay] container up + GPU (stop+start, not restart)"
SUDO docker start autoware >/dev/null 2>&1 || true; sleep 2

echo "==> [replay] deploy gateway + map"
for f in ros_ws_gateway.py find_spawn.py; do SUDO docker cp "$REPO/ros/$f" "autoware:/root/$f" >/dev/null 2>&1; done
SUDO docker cp "$REPO/container_patches/autoware_no_camera.rviz" autoware:/root/autoware_no_camera.rviz >/dev/null 2>&1

echo "==> [replay] stop any live stack (replay is standalone)"
SUDO docker exec autoware bash -c 'pkill -9 -f "e2e_simulator|component_container|perception_stub|ros_ws_gateway|rviz2|rosbag2"; exit 0' >/dev/null 2>&1
SUDO pkill -9 -f CarlaUE4-Linux-Shipping >/dev/null 2>&1
sleep 2

echo "==> [replay] gateway (use_sim_time, reads the bag topics)"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export LANELET_OSM=/root/autoware_map/$TOWN/lanelet2_map.osm; export REPLAY=1; source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py > /tmp/gw.log 2>&1"

echo "==> [replay] play bag (robust while-loop -- ros2 --loop alone can stop): $BAG"
# wrap in while-true: ros2 bag play --loop sometimes plays once then exits;
# the loop guarantees the replay keeps running ("계속 돌기").
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; while true; do ros2 bag play '$BAG' --rate 1.0 >> /tmp/replay.log 2>&1; sleep 1; done"

echo "==> [replay] rviz on the monitor"
DISPLAY=$DISP xhost +local: >/dev/null 2>&1 || true
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export DISPLAY=$DISP; export XAUTHORITY=/root/.Xauthority; source /opt/autoware/setup.bash; rviz2 -d /root/autoware_no_camera.rviz > /tmp/rviz.log 2>&1"

command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1
for i in $(seq 1 20); do SUDO docker exec autoware bash -lc "ss -tlnp 2>/dev/null | grep -q 8765" && { echo "    gateway up (ws:8765)"; break; }; sleep 1; done
echo "Done. Replay looping. Tablet: open ROii app (adb reverse set). rviz on monitor."
