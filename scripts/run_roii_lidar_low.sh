#!/bin/bash
# ROii 4-LiDAR experimental bring-up -- profile LOW.
# Front/Rear AutoL G32 (135deg) + Left/Right Hesai Pandar (360deg) + IMU + GNSS.
# Existing 1-lidar path is untouched; this only sets ROII_PROFILE.
exec env ROII_PROFILE=low bash "$(dirname "$0")/run_localization_demo.sh" "${1:-Town04}"
