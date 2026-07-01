#!/usr/bin/env bash
# Soongsil replay demo: play the 16GB all_topic bag -> RViz (soongsil.rviz) + Soongsil app.
set +e
BAG="${1:-/root/autoware_map/rosbag}"
DK(){ echo 1 | sudo -S docker exec autoware bash -c "$1" 2>/dev/null; }
DKD(){ echo 1 | sudo -S docker exec -d autoware bash -c "$1" 2>/dev/null; }
echo 1 | sudo -S docker stop autoware >/dev/null 2>&1   # nuke stuck bags/procs
echo 1 | sudo -S docker start autoware >/dev/null 2>&1; sleep 5
echo 1 | sudo -S docker cp "$(dirname "$0")/soongsil.rviz" autoware:/root/soongsil.rviz >/dev/null 2>&1
# The bag's /robot_description URDF references package://carla_vehicle_description/mesh/carla_t2_ftm.dae
# (Soongsil recorded with CARLA's vehicle pkg, absent here) -> car wouldn't render. Alias it to the
# bundled lexus mesh + register in the ament index so RViz RobotModel shows a car at base_link.
DK 'D=/opt/autoware/share/carla_vehicle_description; mkdir -p $D/mesh; cp -f /opt/autoware/share/sample_vehicle_description/mesh/lexus.dae $D/mesh/carla_t2_ftm.dae; touch /opt/autoware/share/ament_index/resource_index/packages/carla_vehicle_description'
# NOTE: bag已 records its own /clock (Count 736). Do NOT pass --clock — the synthetic
# clock would fight the recorded one -> /clock oscillates -> RViz "jump back in time" resets
# every frame -> flicker + TF flies away. The recorded /clock drives use_sim_time nodes.
DKD "source /opt/autoware/setup.bash; ros2 bag play $BAG --loop > /tmp/bagplay.log 2>&1"; sleep 3
DKD "export LANELET_OSM=/root/autoware_map/Town04/lanelet2_map.osm; source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
DKD "export DISPLAY=:1 XAUTHORITY=/root/.Xauthority; source /opt/autoware/setup.bash; rviz2 -d /root/soongsil.rviz --ros-args -p use_sim_time:=true > /tmp/rviz.log 2>&1"
command -v adb >/dev/null && { adb reverse tcp:8765 tcp:8765 2>/dev/null; adb shell monkey -p com.keti.soongsil -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }
echo "Soongsil replay up: bag=$BAG | app=com.keti.soongsil | rviz=soongsil.rviz(ego-follow, lidar+tf+ego) on :1"
