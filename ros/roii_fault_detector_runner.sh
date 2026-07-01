#!/bin/bash
# roii_fault_detector를 자동 재시작하는 wrapper
# ROS 2 Humble + FastDDS에서 큰 PointCloud2 메시지로 인한 ExternalShutdown 우회
source /opt/autoware/setup.bash 2>/dev/null
export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml

while true; do
    python3 -u /root/roii_fault_detector.py --ros-args -p use_sim_time:=true >> /tmp/roii_detector.log 2>&1
    echo "[$(date +%H:%M:%S)] roii_fault_detector exited, restarting in 2s..." >> /tmp/roii_detector.log
    sleep 2
done
