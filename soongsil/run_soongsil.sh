#!/usr/bin/env bash
# Soongsil replay demo: play the 16GB all_topic bag -> RViz (soongsil.rviz) + Soongsil app.
set +e
BAG="${1:-/root/autoware_map/rosbag}"
DK(){ echo 1 | sudo -S docker exec autoware bash -c "$1" 2>/dev/null; }
DKD(){ echo 1 | sudo -S docker exec -d autoware bash -c "$1" 2>/dev/null; }
echo 1 | sudo -S docker stop autoware >/dev/null 2>&1   # nuke stuck bags/procs
echo 1 | sudo -S docker start autoware >/dev/null 2>&1; sleep 5
echo 1 | sudo -S docker cp "$(dirname "$0")/soongsil.rviz" autoware:/root/soongsil.rviz >/dev/null 2>&1
DKD "source /opt/autoware/setup.bash; ros2 bag play $BAG --clock --loop > /tmp/bagplay.log 2>&1"; sleep 3
DKD "export LANELET_OSM=/root/autoware_map/Town04/lanelet2_map.osm; source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
DKD "export DISPLAY=:1 XAUTHORITY=/root/.Xauthority; source /opt/autoware/setup.bash; rviz2 -d /root/soongsil.rviz --ros-args -p use_sim_time:=true > /tmp/rviz.log 2>&1"
command -v adb >/dev/null && { adb reverse tcp:8765 tcp:8765 2>/dev/null; adb shell monkey -p com.keti.soongsil -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }
echo "Soongsil replay up: bag=$BAG | app=com.keti.soongsil | rviz=soongsil.rviz(ego-follow, lidar+tf+ego) on :1"
