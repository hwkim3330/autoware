#!/bin/bash
# ROii lidar bring-up -- profile ROOF (single roof-mounted 360-deg sensor,
# sliced into the same 4 named streams as low/mid/high via
# ros/roii_lidar_slicer.py). Sidesteps the corner-mount self-occlusion CARLA
# bug (carla-simulator/carla#9804) that low/mid/high still carry -- see
# container_patches/sensor_kit_calibration_roii_roof.yaml for the full story.
# low/mid/high are untouched siblings, not replaced by this.
exec env ROII_PROFILE=roof bash "$(dirname "$0")/run_localization_demo.sh" "${1:-Town04}"
