#!/bin/bash
# Start the web monitor stack:
#   - rosbridge_server  (ws://localhost:9090)  ROS 2 <-> websocket
#   - web_video_server  (http://localhost:8080) camera topics -> MJPEG
#   - static http server (http://localhost:8000) serves webapp/index.html
# Requires: ros-jazzy-rosbridge-suite, ros-jazzy-web-video-server
# CARLA server + carla-ros-bridge + ego vehicle must already be running.
set -m
source /opt/ros/jazzy/setup.bash

ros2 launch rosbridge_server rosbridge_websocket_launch.xml &
ros2 run web_video_server web_video_server &
( cd "$(dirname "$0")/../webapp" && python3 -m http.server 8000 ) &

echo "Web monitor:  http://localhost:8000"
echo "rosbridge:    ws://localhost:9090   |   video: http://localhost:8080"
echo "Ctrl-C to stop all."
wait
