#!/usr/bin/env bash
# Replay a recorded rosbag -> RViz + tablet gateway, all --clock-synced.
# The bag is self-contained (kinematic_state/pointcloud/tf/objects), so NO CARLA/Autoware
# needed. Usage: run_bag_replay.sh [bag_dir] [map]   (default: the 16GB Soongsil all_topic bag)
set +e
BAG="${1:-/root/autoware_map/rosbag}"
MAP="${2:-Town04}"
DK() { echo 1 | sudo -S docker exec autoware bash -c "$1" 2>/dev/null; }
DKD(){ echo 1 | sudo -S docker exec -d autoware bash -c "$1" 2>/dev/null; }
echo 1 | sudo -S docker start autoware >/dev/null 2>&1; sleep 4
echo "==> stop any live sim/autoware (replay is self-contained)"
echo 1 | sudo -S pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null
DK "pkill -9 -f 'ros2 launch'; pkill -9 -f rviz2; pkill -9 -f ros_ws_gateway; pkill -9 -f 'bag play'; sleep 2"
echo "==> [1/3] play bag --clock --loop: $BAG"
DKD "source /opt/autoware/setup.bash; ros2 bag play $BAG --clock --loop > /tmp/bagplay.log 2>&1"
sleep 3
echo "==> [2/3] gateway (use_sim_time -> tablet ws:8765)"
DKD "export LANELET_OSM=/root/autoware_map/$MAP/lanelet2_map.osm; source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
echo "==> [3/3] rviz (use_sim_time) on :1"
DKD "export DISPLAY=:1 XAUTHORITY=/root/.Xauthority; source /opt/autoware/setup.bash; rviz2 -d /root/roii_clean.rviz --ros-args -p use_sim_time:=true > /tmp/rviz.log 2>&1"
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 2>/dev/null
echo "Done. bag=$BAG | tablet ws://127.0.0.1:8765/ws | rviz on :1"
