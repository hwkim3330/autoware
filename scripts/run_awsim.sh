#!/usr/bin/env bash
# AWSIM (Autoware Unity sim) — WORKING launcher (runs ENTIRELY inside the humble
# `autoware` container, so AWSIM + Autoware share one DDS — no host<->container bridge).
#
# BREAKTHROUGH (2026-06-25): the host is ROS2 jazzy, AWSIM needs humble. Instead of
# bridging, we run AWSIM *inside* the humble container. The blockers + fixes:
#   1. Vulkan in container: `apt install vulkan-tools mesa-vulkan-drivers libvulkan1`
#      -> AWSIM-Demo v2 renders at 6 GB GPU (vulkaninfo shows the RTX 3090).
#   2. Zombie AWSIM procs from relaunches left STALE DDS publishers; the container kept
#      discovering a dead zombie's /clock publisher -> SILENT. Fix: clean container
#      `docker stop && docker start` (NOT restart - restart breaks CUDA/NVML) reaps
#      zombies + clears /dev/shm. Then launch exactly ONE AWSIM.
#   3. Low fd limit: container `ulimit -n` = 1024 -> FastDDS SHM "open_and_lock_file
#      failed" with ~118 participants. Launch Autoware with `ulimit -n 65536`.
#   4. AWSIM canNOT take a FastDDS UDP profile (bundled FastDDS fails init -> no render).
#      So SHM is mandatory for AWSIM. Default DDS only.
#   5. e2e must use `launch_sensing_driver:=false` (still partially loads Nebula; see
#      docs/awsim_setup.md - sensor-kit pipeline is the remaining gap).
#
# STILL-OPEN (sensor pipeline): distortion_corrector "IMU time_stamp is too late" ->
# no concatenated cloud -> NDT no input -> /initialpose3d never set. See docs.
set +e
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
DK() { echo 1 | sudo -S docker exec autoware bash -c "$1" 2>/dev/null; }
DKD() { echo 1 | sudo -S docker exec -d autoware bash -c "$1" 2>/dev/null; }
MAP=/root/autoware_map/shinjuku
AWSIM=/opt/awsim/AWSIM-Demo

echo "==> [0/4] one-time container prep (idempotent)"
DK "command -v vulkaninfo >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vulkan-tools mesa-vulkan-drivers libvulkan1; }"
DK "test -x $AWSIM/AWSIM-Demo.x86_64 || echo 'MISSING: docker cp ~/AWSIM/AWSIM-Demo autoware:/opt/awsim/'"
# Keep distortion ENABLED: it produces /sensing/lidar/top/pointcloud_before_sync (the chain
# needs it; disabling it kills before_sync entirely). The "Twist/IMU too late" warnings are
# intermittent - before_sync still flows (~26k pts). Ensure the default is back to true.
DK "sed -i 's|<arg name=\\\"use_distortion_corrector\\\" default=\\\"false\\\"/>|<arg name=\\\"use_distortion_corrector\\\" default=\\\"true\\\"/>|' /opt/autoware/share/awsim_sensor_kit_launch/launch/lidar.launch.xml"
SUDO docker update --cpuset-cpus=0-15 autoware   # use all cores (0,8 were host-reserved)
# DDS transport: default SHM+UDP (shared host /dev/shm via --ipc=host) is what works for
# data flow + localization. (Tried: isolated /dev/shm -> no data flow; UDP-only profile ->
# "Not enough memory in the buffer stream" on node init + preprocessing breaks.) Known
# residual: FastDDS SHM doesn't deliver the TRANSIENT_LOCAL latched route/map to the
# scenario_selector process -> no trajectory -> autonomous unavailable (driving blocked).
SUDO ip link set lo multicast on
FASTDDS=""   # keep default DDS; see note above
# install the before_sync->concatenated relay node into the container
echo 1 | sudo -S docker exec -i autoware bash -c 'cat > /opt/cloud_relay.py' << 'PYEOF'
import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import PointCloud2
rclpy.init(); n=Node('cloud_relay')
pub = n.create_publisher(PointCloud2, '/sensing/lidar/concatenated/pointcloud', qos_profile_sensor_data)
c=[0]
def cb(m):
    # AWSIM publishes row_step=0 -> NDT's PCL conversion yields an EMPTY cloud (pose_buffer
    # < 2 forever). Reconstruct row_step so NDT gets real points.
    if m.row_step == 0 and m.width > 0 and m.point_step > 0:
        m.height = 1; m.row_step = m.width * m.point_step
    pub.publish(m); c[0]+=1
    if c[0] % 50 == 1: n.get_logger().info(f"relayed {c[0]} w={m.width} row_step={m.row_step}")
n.create_subscription(PointCloud2, '/sensing/lidar/top/pointcloud_before_sync', cb, qos_profile_sensor_data)
n.get_logger().info("relay (row_step-fixing) before_sync -> concatenated up")
rclpy.spin(n)
PYEOF

# copy the perception stub (clear-road for the planner) + tablet gateway into the container
REPO=/home/kim/autoware-keti
SUDO docker cp "$REPO/ros/perception_stub.py" autoware:/root/perception_stub.py 2>/dev/null
SUDO docker cp "$REPO/ros/ros_ws_gateway.py"  autoware:/root/ros_ws_gateway.py  2>/dev/null

echo "==> [1/4] clean reset (reap zombies + clear stale DDS/SHM)"
# container shares HOST /dev/shm (--ipc=host -v /dev/shm) so stop/start does NOT clear it;
# while the container is stopped (nothing holding shm) wipe stale FastDDS lock/segment files.
SUDO docker stop autoware >/dev/null
SUDO bash -c 'rm -f /dev/shm/*fastrtps* /dev/shm/sem.*fastrtps* /dev/shm/*fastdds* 2>/dev/null; true'
SUDO docker start autoware >/dev/null; sleep 8

echo "==> [2/4] launch AWSIM-Demo v2 inside container (Vulkan + host X :1, default SHM)"
DKD "unset AMENT_PREFIX_PATH ROS_DISTRO RMW_IMPLEMENTATION LD_LIBRARY_PATH PYTHONPATH
     export DISPLAY=:1 XAUTHORITY=/root/.Xauthority VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
     ulimit -n 65536
     cd $AWSIM && ./AWSIM-Demo.x86_64 -force-vulkan -screen-width 1280 -screen-height 720 > /tmp/awsim_demo.log 2>&1"
sleep 10; DISPLAY=:1 wmctrl -a AWSIM 2>/dev/null; sleep 33
echo "    AWSIM GPU: $(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>/dev/null | grep -i awsim || echo 'NOT RENDERING')"

# AWSIM-Demo v2 has ONE lidar ("top") -> use awsim_sensor_kit (single-lidar). awsim_LABS
# kit expects top+left+right -> concatenate skips (left/right nullptr) -> no NDT input.
echo "==> [3/4] Autoware e2e on Shinjuku (awsim_sensor_kit = AWSIM-Demo's single-lidar match)"
DKD "$FASTDDS ulimit -n 65536; export DISPLAY=:1 XAUTHORITY=/root/.Xauthority
     source /opt/autoware/setup.bash
     # do NOT pass launch_sensing_driver:=false - it disables the whole sensing PIPELINE
     # (crop/distortion/concatenate), not just the hw driver. The Nebula/velodyne driver
     # loads + crashes harmlessly (we feed AWSIM's raw cloud); preprocessing still runs.
     ros2 launch autoware_launch e2e_simulator.launch.xml \
       vehicle_model:=sample_vehicle sensor_model:=awsim_sensor_kit map_path:=$MAP \
       launch_vehicle_interface:=true perception:=false rviz:=false \
       > /tmp/awsim_aw.log 2>&1"
sleep 48
# give AWSIM 3 dedicated phys cores (0-2), Autoware the rest - keeps AWSIM lidar at 10Hz
DK "for p in \$(pgrep -f AWSIM-Demo); do taskset -cp 0-2,8-10 \$p >/dev/null 2>&1; done
    for p in \$(pgrep -f component_container); do taskset -cp 3-7,11-15 \$p >/dev/null 2>&1; done"
# Start the relay + perception stub EARLY (right after e2e) so they join the SHM graph and
# integrate into the diagnostic aggregator. relay: before_sync->concatenated (row_step fix)
# feeds NDT. perception_stub: empty objects + obstacle pc + clear occupancy grid so the
# planner generates a trajectory without the full perception stack.
echo "==> [3.4] relay (before_sync->concatenated) + perception_stub (clear road)"
DKD "$FASTDDS ulimit -n 65536; source /opt/autoware/setup.bash; python3 /opt/cloud_relay.py > /tmp/relay.log 2>&1"
DKD "$FASTDDS ulimit -n 65536; source /opt/autoware/setup.bash; python3 -u /root/perception_stub.py --ros-args -p use_sim_time:=true > /tmp/percstub.log 2>&1"
sleep 14   # let NDT start matching off the relayed concatenated cloud before seeding

echo "==> [3.5] seed localization (AWSIM gnss pose: Shinjuku MGRS 54SUE x81378 y49917 yaw34)"
DK "$FASTDDS . /opt/autoware/setup.bash; ulimit -n 65536
   timeout 20 ros2 service call /api/localization/initialize autoware_adapi_v1_msgs/srv/InitializeLocalization \
   '{pose: [{header: {frame_id: map}, pose: {pose: {position: {x: 81377.98, y: 49917.33, z: 43.09}, orientation: {z: 0.30071, w: 0.95372}}, covariance: [1,0,0,0,0,0, 0,1,0,0,0,0, 0,0,0.01,0,0,0, 0,0,0,0.01,0,0, 0,0,0,0,0.01,0, 0,0,0,0,0,0.2]}}]}'" >/dev/null 2>&1
sleep 8

echo "==> [3.6] gateway (Tesla tablet feed, WS :8765 - the primary 3D visualization)"
DKD "$FASTDDS ulimit -n 65536
     export LANELET_OSM=/root/autoware_map/shinjuku/lanelet2_map.osm NIRO_ORIGIN='35.2376422,138.7889491' NIRO_SITE='shinjuku' DISPLAY=:1 XAUTHORITY=/root/.Xauthority
     source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
# NOTE: do NOT auto-launch RViz on :1 - it steals X focus and Unity PAUSES AWSIM (drops to
# 364MB, sensors stop, localization dies; AWSIM then won't resume without a container
# stop/start). AWSIM (Unity) must keep focus on its display. The Tesla tablet (ws :8765) is
# the live 3D view instead. To use RViz, give AWSIM its OWN X display (:2) so it never loses
# focus (see docs/awsim_setup.md), then run RViz on :1.
sleep 4; DISPLAY=:1 wmctrl -a AWSIM 2>/dev/null   # keep AWSIM focused

echo "==> [4/4] status"
DK "echo 'relay: '\$(grep relayed /tmp/relay.log 2>/dev/null|tail -1)
    echo 'gateway: '\$(pgrep -fc ros_ws_gateway) ' procs ; perception_stub: '\$(pgrep -fc perception_stub)' procs'
    echo 'NDT pose_buffer<2 (stops growing when converged): '\$(grep -c 'pose_buffer_.size() < 2' /tmp/awsim_aw.log)"
echo "Done. Tablet feed: ws://127.0.0.1:8765/ws  (app: com.keti.awsim_tesla, adb reverse tcp:8765 tcp:8765)"
