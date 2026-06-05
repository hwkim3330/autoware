#!/bin/bash
# Start carla-ros-bridge (ROS 2 Jazzy) against a running CARLA server on :2000.
# The workspace must be built first — see docs/ros2-jazzy.md.
set -e
ROS_WS="${ROS_WS:-$HOME/carla-ros-ws}"
source /opt/ros/jazzy/setup.bash
source "$ROS_WS/install/setup.bash"
exec ros2 launch carla_ros_bridge carla_ros_bridge.launch.py \
  host:=localhost port:=2000 timeout:=120 "$@"
