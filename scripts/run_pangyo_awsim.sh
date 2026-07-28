#!/usr/bin/env bash
# AWSIM + Autoware on the KOREAN map (Pangyo), instead of AWSIM's shipped Shinjuku.
#
#   bash scripts/run_pangyo_awsim.sh
#
# The simulator binary is built from ~/AWSIM_src by
# Assets/Editor/AwsimKorea/PangyoBuilder.cs; the map comes from the V-World
# pipeline in ~/awsim_korea_map. Everything runs INSIDE the `autoware`
# container so simulator and Autoware share one DDS domain -- same reasoning as
# run_awsim.sh, whose sequence this follows.
#
# WHAT IS DIFFERENT FROM run_awsim.sh
#   map      /root/autoware_map/pangyo_regen  (projector_type: local, not MGRS)
#   binary   /opt/awsim/AWSIM_pangyo/AWSIM_Pangyo.x86_64
#   origin   37.4028153,127.1050297  (Pangyo / KETI)
#   seed     computed from the lanelet the scene spawns the ego on, see [3.5]
#   cpus     not pinned -- the box is free for this, so let Linux schedule
#
# WHY THE MAP HAD TO BE REBUILT FIRST (see ~/awsim_korea_map)
#   The pangyo_awsim directory in use until 2026-07-28 mixed two lineages: a
#   lanelet converted through OpenDRIVE (routable, 92% successors, but in a
#   DIFFERENT coordinate frame from its own point cloud) and the generator's own
#   lanelet (right frame, but zero shared nodes so nothing was routable at all).
#   pangyo_regen is one lineage throughout: generated, welded to 86.9%
#   successors, and draped with one terrain field across cloud, lanelet and mesh.
set +e
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
DK()   { echo 1 | sudo -S docker exec autoware bash -c "$1" 2>/dev/null; }
DKD()  { echo 1 | sudo -S docker exec -d autoware bash -c "$1" 2>/dev/null; }

REPO=/home/kim/autoware-keti
HOST_SIM=/home/kim/AWSIM_pangyo
HOST_MAP=/home/kim/autoware_map/pangyo_regen
AWSIM=/opt/awsim/AWSIM_pangyo
MAP=/root/autoware_map/pangyo_regen
FASTDDS="export ROS_DISCOVERY_SERVER=127.0.0.1:11811;"

# Pangyo seed pose. Derived from the lanelet the scene builder spawns the ego on
# (the best-connected lane); the ego sits 3.00 m off the nearest boundary node,
# which is exactly the generator's lane half-width -- a useful check that the
# scene and the map still agree.
SX=-429.44; SY=556.48; SZ=9.88; QZ=-0.60273; QW=0.79795

for f in "$HOST_SIM/AWSIM_Pangyo.x86_64" "$HOST_MAP/lanelet2_map.osm" "$HOST_MAP/pointcloud_map.pcd"; do
  [ -e "$f" ] || { echo "MISSING: $f"; exit 1; }
done

echo "==> [0/5] container prep + copy simulator and map in"
DK "command -v vulkaninfo >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vulkan-tools mesa-vulkan-drivers libvulkan1; }"
DK "mkdir -p $AWSIM $MAP"
# Only re-copy when the build is newer; the player is 435 MB.
if [ "$(DK "cat $AWSIM/.stamp 2>/dev/null")" != "$(stat -c %Y "$HOST_SIM/AWSIM_Pangyo.x86_64")" ]; then
  echo "    copying player (435 MB) ..."
  SUDO docker cp "$HOST_SIM/." autoware:$AWSIM/
  DK "echo $(stat -c %Y "$HOST_SIM/AWSIM_Pangyo.x86_64") > $AWSIM/.stamp; chmod +x $AWSIM/AWSIM_Pangyo.x86_64"
fi
SUDO docker cp "$HOST_MAP/." autoware:$MAP/
# Same duplicate-relay removal as the Shinjuku path: awsim_sensor_kit_launch's
# lidar.launch.xml publishes concatenated/pointcloud itself, racing cloud_relay.py.
DK "sed -i '/<load_composable_node target=/,/<\\/load_composable_node>/d' /opt/autoware/share/awsim_sensor_kit_launch/launch/lidar.launch.xml"
SUDO docker update --cpuset-cpus="" autoware >/dev/null 2>&1

echo "==> [1/5] clean reset (reap zombies + clear stale DDS/SHM)"
SUDO docker stop autoware >/dev/null
SUDO bash -c 'rm -f /dev/shm/*fastrtps* /dev/shm/sem.*fastrtps* /dev/shm/*fastdds* 2>/dev/null; true'
SUDO docker start autoware >/dev/null; sleep 8

echo "==> [1.5/5] FastDDS discovery server (id 0 @ 127.0.0.1:11811)"
DKD "source /opt/ros/humble/setup.bash; fastdds discovery -i 0 -l 127.0.0.1 -p 11811 > /tmp/dserver.log 2>&1"
sleep 3

echo "==> [2/5] launch AWSIM Pangyo (Vulkan, host X :1, discovery server)"
DKD "unset AMENT_PREFIX_PATH ROS_DISTRO RMW_IMPLEMENTATION LD_LIBRARY_PATH PYTHONPATH
     export DISPLAY=:1 XAUTHORITY=/root/.Xauthority VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
     export ROS_DISCOVERY_SERVER=127.0.0.1:11811
     ulimit -n 65536
     cd $AWSIM && ./AWSIM_Pangyo.x86_64 -force-vulkan -screen-width 1280 -screen-height 720 \
       > /tmp/awsim_pangyo.log 2>&1"
sleep 10; DISPLAY=:1 wmctrl -a AWSIM 2>/dev/null; sleep 30
echo "    GPU: $(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>/dev/null | grep -i pangyo || echo 'NOT RENDERING')"

echo "==> [3/5] Autoware e2e on Pangyo (awsim_sensor_kit = single-lidar match)"
DKD "$FASTDDS ulimit -n 65536; export DISPLAY=:1 XAUTHORITY=/root/.Xauthority
     source /opt/autoware/setup.bash
     ros2 launch autoware_launch e2e_simulator.launch.xml \
       vehicle_model:=sample_vehicle sensor_model:=awsim_sensor_kit map_path:=$MAP \
       launch_vehicle_interface:=true perception:=false rviz:=false \
       > /tmp/awsim_pangyo_aw.log 2>&1"
sleep 48

echo "==> [3.4] relay (before_sync -> concatenated) + perception stub"
DKD "$FASTDDS ulimit -n 65536; source /opt/autoware/setup.bash; python3 /opt/cloud_relay.py > /tmp/relay.log 2>&1"
DKD "$FASTDDS ulimit -n 65536; source /opt/autoware/setup.bash; python3 -u /root/perception_stub.py --ros-args -p use_sim_time:=true > /tmp/percstub.log 2>&1"
sleep 14

echo "==> [3.5] seed localization at ($SX, $SY, $SZ)"
DK "$FASTDDS . /opt/autoware/setup.bash; ulimit -n 65536
   timeout 12 ros2 service call /api/localization/initialize autoware_adapi_v1_msgs/srv/InitializeLocalization \
   '{pose: [{header: {frame_id: map}, pose: {pose: {position: {x: $SX, y: $SY, z: $SZ}, orientation: {z: $QZ, w: $QW}}, covariance: [1,0,0,0,0,0, 0,1,0,0,0,0, 0,0,0.01,0,0,0, 0,0,0,0.01,0,0, 0,0,0,0,0.01,0, 0,0,0,0,0,0.2]}}]}'" >/dev/null 2>&1
DK "$FASTDDS . /opt/autoware/setup.bash; ulimit -n 65536
   for i in 1 2 3 4 5; do ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
   '{header: {frame_id: map}, pose: {pose: {position: {x: $SX, y: $SY, z: $SZ}, orientation: {z: $QZ, w: $QW}}, covariance: [1,0,0,0,0,0, 0,1,0,0,0,0, 0,0,0.01,0,0,0, 0,0,0,0.01,0,0, 0,0,0,0,0.01,0, 0,0,0,0,0,0.2]}}}' >/dev/null 2>&1; sleep 0.5; done"
sleep 8

echo "==> [4/5] gateway (tablet feed, WS :8765)"
DKD "$FASTDDS ulimit -n 65536
     export LANELET_OSM=$MAP/lanelet2_map.osm NIRO_ORIGIN='37.4028153,127.1050297' NIRO_SITE='pangyo'
     export DISPLAY=:1 XAUTHORITY=/root/.Xauthority
     source /opt/autoware/setup.bash
     python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1
sleep 6

echo "==> [5/5] status"
DK "$FASTDDS . /opt/autoware/setup.bash
    echo -n '    lidar     : '; timeout 8 ros2 topic hz /sensing/lidar/concatenated/pointcloud 2>/dev/null | grep -m1 average || echo 'NO DATA'
    echo -n '    NDT pose  : '; timeout 8 ros2 topic hz /localization/kinematic_state 2>/dev/null | grep -m1 average || echo 'NO DATA'
    echo -n '    /clock    : '; timeout 8 ros2 topic hz /clock 2>/dev/null | grep -m1 average || echo 'NO DATA'"
echo "Done. Tablet: ws://127.0.0.1:8765/ws   Logs: /tmp/awsim_pangyo.log /tmp/awsim_pangyo_aw.log"
