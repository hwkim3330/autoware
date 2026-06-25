#!/usr/bin/env bash
# AWSIM (Autoware Unity sim) launcher + the host DDS config it needs.
#
# STATUS (2026-06-25): blocked by a host ROS-version mismatch — see docs/awsim_setup.md.
#   - AWSIM-Labs v1.6.1 (~/AWSIM/awsim_labs/) + AWSIM v2.0.1 (~/AWSIM/AWSIM-Demo/) both
#     need ROS2 HUMBLE libs. The host runs ROS2 JAZZY -> AWSIM's bundled librcl.so
#     fails (UnsatisfiedLinkError: libspdlog.so.1 / libfmt.so.8 are jazzy versions).
#   - Running AWSIM inside the humble container loads librcl fine but the Unity/HDRP
#     scene won't render (no Vulkan ICD in the container) -> sim idle, no /sensing topics.
# RESOLUTION PATHS (need a focused session): (a) install ROS2 humble RUNTIME libs on the
# host so AWSIM runs natively where Vulkan works, or (b) add the NVIDIA Vulkan ICD +
# HDRP support into the container.
#
# This script does the parts that ARE correct so they're ready once the above is fixed.
set +e
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
LABS=/home/kim/AWSIM/awsim_labs/awsim_labs_v1.6.1
MAP=/root/autoware_map/shinjuku

echo "==> [1/3] AWSIM-Labs DDS config (REQUIRED: localhost multicast + big UDP buffers)"
SUDO ip link set lo multicast on            # DDS data over loopback needs multicast
SUDO sysctl -w net.core.rmem_max=2147483647 >/dev/null
SUDO sysctl -w net.ipv4.ipfrag_time=3 net.ipv4.ipfrag_high_thresh=134217728 >/dev/null
echo "    lo multicast: $(ip link show lo | grep -o MULTICAST || echo OFF)"

echo "==> [2/3] launch AWSIM-Labs (standalone — do NOT source ROS2; it bundles its own)"
# NOTE: on the host this fails (jazzy). Provide humble libspdlog.so.1.9.2 + libfmt.so.8
# into $LABS/awsim_labs_Data/Plugins/ (copied from the humble container) so $ORIGIN RPATH
# resolves them, OR run where /opt/ros/humble exists.
cd "$LABS" 2>/dev/null && chmod +x awsim_labs.x86_64
( unset AMENT_PREFIX_PATH ROS_DISTRO RMW_IMPLEMENTATION
  DISPLAY=:1 ./awsim_labs.x86_64 -force-vulkan > /tmp/awsim_labs.log 2>&1 & )
echo "    AWSIM-Labs launching (check /tmp/awsim_labs.log + ~/.config/unity3d/AWF/'AWSIM Labs'/Player.log)"
sleep 45

echo "==> [3/3] Autoware e2e on Shinjuku (awsim models; default DDS, perception off)"
# inside the autoware (humble) container; AWSIM publishes /sensing/* /clock /vehicle/status
SUDO docker exec -d autoware bash -lc "export DISPLAY=:1; export XAUTHORITY=/root/.Xauthority; source /opt/autoware/setup.bash && ros2 launch autoware_launch e2e_simulator.launch.xml vehicle_model:=awsim_labs_vehicle sensor_model:=awsim_labs_sensor_kit map_path:=$MAP launch_vehicle_interface:=true perception:=false rviz:=true > /tmp/awsim_aw.log 2>&1"
echo "Done. Verify sensors: docker exec autoware bash -lc 'source /opt/autoware/setup.bash; ros2 topic hz /sensing/lidar/concatenated/pointcloud'"
echo "If 0 topics: AWSIM isn't publishing (see docs/awsim_setup.md — host humble-libs / container-Vulkan issue)."
