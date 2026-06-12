#!/bin/bash
# Build the ROiiSensorFaultPanel rviz plugin inside the autoware container
# (overlay workspace /opt/roii_ws; sourced by the ROii rviz launch).
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUDO() { timeout 1200 sudo -S "$@" < <(echo 1); }
SUDO docker exec autoware bash -c "mkdir -p /opt/roii_ws/src"
SUDO docker cp "$REPO/rviz_plugins/roii_sensor_fault_panel" autoware:/opt/roii_ws/src/
SUDO docker exec autoware bash -lc "
  source /opt/ros/humble/setup.bash 2>/dev/null || source /opt/autoware/setup.bash
  cd /opt/roii_ws && colcon build --packages-select roii_sensor_fault_panel \
    --cmake-args -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5"
SUDO docker exec autoware bash -c \
  "ls /opt/roii_ws/install/roii_sensor_fault_panel/lib/*.so && echo 'PANEL BUILD OK'"
