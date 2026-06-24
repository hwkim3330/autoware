#!/usr/bin/env bash
# Niro real-vehicle multimode localization — bring-up entry (문서 우선순위 기준).
#
# Subcommands:
#   sensing     Virtual Sensor Driver (4 adapters -> standard /sensing topics)
#   multimode   Pose Merger + Mode Manager + LiDAR Fault Adapter (이중측위 융합 코어)
#   core        sensing + multimode together
#   fault       inject a LiDAR fault for N seconds (default 5) then heal
#   mode        request a mode: normal | lidar_fault | auto
#   status      echo the live multimode status/mode/transition topics
#
# This is REAL-VEHICLE code — it expects the Niro's sensor drivers + Autoware on
# the same ROS2 graph. On this dev box (no Niro hardware) `multimode` still runs
# standalone; it just reports inputs stale until the pipelines feed it.
set -e
NIRO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH="$NIRO/launch"
: "${ROS_DISTRO:=humble}"
source "/opt/ros/${ROS_DISTRO}/setup.bash" 2>/dev/null || true

cmd="${1:-core}"; shift || true
case "$cmd" in
  sensing)   exec ros2 launch "$LAUNCH/niro_sensor_adapter.launch.py" ;;
  multimode) exec ros2 launch "$LAUNCH/niro_multimode_localization.launch.py" ;;
  core)
    ros2 launch "$LAUNCH/niro_sensor_adapter.launch.py" &
    SP=$!
    trap 'kill $SP 2>/dev/null' EXIT
    exec ros2 launch "$LAUNCH/niro_multimode_localization.launch.py"
    ;;
  fault)
    dur="${1:-5}"
    echo "injecting LiDAR fault for ${dur}s ..."
    ros2 topic pub --once /test/fault_injection/lidar std_msgs/msg/Bool "{data: true}"
    sleep "$dur"
    ros2 topic pub --once /test/fault_injection/lidar std_msgs/msg/Bool "{data: false}"
    echo "healed."
    ;;
  mode)
    m="${1:-auto}"
    ros2 topic pub --once /multimode/mode_request std_msgs/msg/String "{data: '$m'}"
    echo "requested mode: $m"
    ;;
  status)
    exec ros2 topic echo /multimode/status
    ;;
  *)
    echo "usage: run_niro.sh {sensing|multimode|core|fault [sec]|mode <m>|status}"; exit 1 ;;
esac
