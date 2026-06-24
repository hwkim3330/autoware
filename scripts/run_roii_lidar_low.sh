#!/bin/bash
# ROii 4-LiDAR experimental bring-up -- profile LOW.
# Front/Rear AutoL G32 (135deg) + Left/Right Hesai Pandar (360deg) + IMU + GNSS.
# Existing 1-lidar path is untouched; this only sets ROII_PROFILE.
# ROII_PROFILE=low installs the ROii 4-lidar configs (sensor kit + preprocessor)
# AND the low-density profile; it's the real 4-lidar path (the LIDARS=4 branch is
# a separate generic one). The "[2/5] ... (LIDARS=1)" echo is cosmetic here.
exec env ROII_PROFILE=low bash "$(dirname "$0")/run_localization_demo.sh" "${1:-Town04}"
