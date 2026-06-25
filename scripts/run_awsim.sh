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
SUDO docker update --cpuset-cpus=0-15 autoware   # use all cores (0,8 were host-reserved)

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
DKD "ulimit -n 65536; export DISPLAY=:1 XAUTHORITY=/root/.Xauthority
     source /opt/autoware/setup.bash
     ros2 launch autoware_launch e2e_simulator.launch.xml \
       vehicle_model:=sample_vehicle sensor_model:=awsim_sensor_kit map_path:=$MAP \
       launch_vehicle_interface:=true launch_sensing_driver:=false perception:=false rviz:=false \
       > /tmp/awsim_aw.log 2>&1"
sleep 48
# give AWSIM 3 dedicated phys cores (0-2), Autoware the rest - keeps AWSIM lidar at 10Hz
DK "for p in \$(pgrep -f AWSIM-Demo); do taskset -cp 0-2,8-10 \$p >/dev/null 2>&1; done
    for p in \$(pgrep -f component_container); do taskset -cp 3-7,11-15 \$p >/dev/null 2>&1; done"
echo "==> [3.5] seed localization (AWSIM ego pose: Shinjuku MGRS 54SUE x81381 y49920 yaw35)"
DK ". /opt/autoware/setup.bash; ulimit -n 65536
   ros2 service call /api/localization/initialize autoware_adapi_v1_msgs/srv/InitializeLocalization \
   '{pose: [{header: {frame_id: map}, pose: {pose: {position: {x: 81381.7, y: 49920.2, z: 41.6}, orientation: {z: 0.30071, w: 0.95372}}, covariance: [1,0,0,0,0,0, 0,1,0,0,0,0, 0,0,0.01,0,0,0, 0,0,0,0.01,0,0, 0,0,0,0,0.01,0, 0,0,0,0,0,0.2]}}]}'" >/dev/null 2>&1

echo "==> [4/4] status (probe with ulimit 65536; CLI probes are flaky at this DDS scale)"
DK "echo 'AWSIM /clock subs: '\$(. /opt/ros/humble/setup.bash; ros2 topic info /clock 2>/dev/null|grep -o 'Subscription count: [0-9]*')
    echo 'SHM lock errors: '\$(grep -c open_and_lock_file /tmp/awsim_aw.log)
    echo 'distortion IMU-late warns: '\$(grep -c 'IMU time_stamp is too late' /tmp/awsim_aw.log)"
echo "Done. Tesla tablet app: ~/awsim_tesla (com.keti.awsim_tesla)."
