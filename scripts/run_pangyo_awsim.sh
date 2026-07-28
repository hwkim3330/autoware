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
#   map      /root/autoware_map/pangyo_regen  (MGRS 52SCG, re-authored by to_mgrs_frame.py)
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
# AWSIM ships its own standalone FastDDS; the container has another. Put them on
# a private domain with UDP-localhost transport instead of a discovery server.
#
# MEASURED 2026-07-28: with the discovery server, AWSIM initialised ROS2 cleanly
# (log: "RMW: rmw_fastrtps_cpp", zero exceptions) and still published NOTHING --
# `ros2 topic list` saw 2 topics under either RMW. Same binary, same scene, with
# ROS_DOMAIN_ID=77 + ROS_LOCALHOST_ONLY=1: 26 topics, /clock at 98.9 Hz. The two
# FastDDS builds could not complete discovery through the server; localhost UDP
# also sidesteps the shared-memory segment incompatibility that produced
# "Bad alloc deserializing ParticipantEntitiesInfo" earlier.
FASTDDS="export ROS_DOMAIN_ID=77 ROS_LOCALHOST_ONLY=1; unset ROS_DISCOVERY_SERVER;"

# Pangyo seed pose, in the map's MGRS 52SCG frame.
#
# to_mgrs_frame.py shifted the lanelet and cloud by (+32278.5, +41244.6) so the
# coordinates sit inside the 100 km square and AWSIM's GNSS encoder stops
# throwing. The scene spawns the ego near the map centre; converting that Unity
# position back gives the values below, and the nearest lane boundary lands
# exactly 3.00 m away -- the generator's lane half-width, which is the check that
# the conversion is right.
SX=32311.49; SY=41198.32; SZ=4.68; SQZ=0.81781; SQW=0.57549
#
# Goal: 80% along the second lanelet of the successor chain out of the ego's lane
# -- 687 m, two lanelets. Deliberately not the chain's END NODE: a goal sitting
# exactly on a lanelet boundary is the one place lanelet matching has nothing to
# match against.
GX=31880.42; GY=41733.68; GQZ=0.83819; GQW=0.54538

for f in "$HOST_SIM/AWSIM_Pangyo.x86_64" "$HOST_MAP/lanelet2_map.osm" "$HOST_MAP/pointcloud_map.pcd"; do
  [ -e "$f" ] || { echo "MISSING: $f"; exit 1; }
done

echo "==> [0/5] container prep + copy simulator and map in"
DK "command -v vulkaninfo >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vulkan-tools mesa-vulkan-drivers libvulkan1; }"
DK "mkdir -p $AWSIM $MAP"
# Re-copy when the build is newer. Stamp on _Data/level0, NOT on the .x86_64:
# that file is a 15 KB launcher stub whose mtime does not move between builds, so
# stamping it meant the container silently kept an old player. Cost hours -- the
# ego was fixed on the host and still fell inside the container.
BUILD_STAMP=$(stat -c %Y "$HOST_SIM/AWSIM_Pangyo_Data/level0" 2>/dev/null || echo 0)
if [ "$(DK "cat $AWSIM/.stamp 2>/dev/null")" != "$BUILD_STAMP" ]; then
  echo "    copying player ($(du -sh "$HOST_SIM" | cut -f1)) ..."
  DK "rm -rf $AWSIM"; DK "mkdir -p $AWSIM"
  SUDO docker cp "$HOST_SIM/." autoware:$AWSIM/
  DK "echo $BUILD_STAMP > $AWSIM/.stamp; chmod +x $AWSIM/AWSIM_Pangyo.x86_64"
else
  echo "    player already current"
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

echo "==> [2/5] launch AWSIM Pangyo (Vulkan, host X :1, domain 77 localhost)"
DKD "unset AMENT_PREFIX_PATH ROS_DISTRO RMW_IMPLEMENTATION LD_LIBRARY_PATH PYTHONPATH ROS_DISCOVERY_SERVER
     export DISPLAY=:1 XAUTHORITY=/root/.Xauthority VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
     export ROS_DOMAIN_ID=77 ROS_LOCALHOST_ONLY=1
     ulimit -n 65536
     cd $AWSIM && ./AWSIM_Pangyo.x86_64 -force-vulkan -screen-width 1280 -screen-height 720 \
       -logfile /tmp/awsim_player.log > /tmp/awsim_pangyo.log 2>&1"
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

# Seeding used to happen here, before the gateway. It now happens inside
# [4.5] together with routing and engage: the seed has to be RE-VERIFIED right
# before routing anyway, because NDT converges to a heading ~87 deg off the lane
# on maybe two attempts in three (measured 2026-07-28 -- seeds 1 and 2 landed at
# -167.9 and -162.8 deg, seed 3 at 109.7). Doing it in two places just meant the
# second call got "The route is already set".
SUDO docker cp "$REPO/ros/drive_pangyo.py" autoware:/root/drive_pangyo.py >/dev/null 2>&1
SUDO docker cp "$REPO/ros/watch_stop.py" autoware:/root/watch_stop.py >/dev/null 2>&1

echo "==> [4/5] gateway (tablet feed, WS :8765)"
DKD "$FASTDDS ulimit -n 65536
     export LANELET_OSM=$MAP/lanelet2_map.osm NIRO_ORIGIN='37.4028153,127.1050297' NIRO_SITE='pangyo'
     export DISPLAY=:1 XAUTHORITY=/root/.Xauthority
     source /opt/autoware/setup.bash
     python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1
sleep 6

echo "==> [4.5/5] route + engage autonomous"
# Monitor first, so the drive is observed from before engage. It logs NDT against
# AWSIM's noiseless GNSS, which is the only way to tell a localization drift from
# a vehicle that has already left the road.
DKD "$FASTDDS ulimit -n 65536; source /opt/autoware/setup.bash
     python3 -u /root/watch_stop.py --watch 120 > /tmp/watch.log 2>&1"
sleep 3
DK "$FASTDDS . /opt/autoware/setup.bash; ulimit -n 65536
   python3 -u /root/drive_pangyo.py --seed $SX $SY 5.4 $SQZ $SQW --goal $GX $GY $GQZ $GQW --watch 40 2>&1" 2>&1 | sed 's/^/  /'

echo "==> [5/5] status"
DK "$FASTDDS . /opt/autoware/setup.bash
    echo -n '    lidar     : '; timeout 8 ros2 topic hz /sensing/lidar/concatenated/pointcloud 2>/dev/null | grep -m1 average || echo 'NO DATA'
    echo -n '    NDT pose  : '; timeout 8 ros2 topic hz /localization/kinematic_state 2>/dev/null | grep -m1 average || echo 'NO DATA'
    echo -n '    /clock    : '; timeout 8 ros2 topic hz /clock 2>/dev/null | grep -m1 average || echo 'NO DATA'"
echo "Done. Tablet: ws://127.0.0.1:8765/ws   Logs: /tmp/awsim_pangyo.log /tmp/awsim_pangyo_aw.log"
