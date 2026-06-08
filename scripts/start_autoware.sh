#!/bin/bash
# Bring up the full Autoware stack in docker, connected to a running native
# CARLA 0.9.16 (localhost:2000), with rviz on the host monitor.
# Requires: driver 535, CARLA running (scripts/start_carla_native.sh), maps in
# ~/autoware_map (scripts/download_carla_maps.sh), Autoware ML artifacts present
# in the container (~/autoware_data, downloaded once via ansible — baked into the
# 'autoware-ready' image if committed).
set -e
TOWN="${1:-Town01}"
IMAGE="${AUTOWARE_IMAGE:-autoware-ready}"   # falls back below if missing
MAPS="${HOME}/autoware_map"

# Allow the container to use the host X server (rviz).
GS=$(pgrep -x gnome-shell | head -1)
XA=$(tr '\0' '\n' </proc/$GS/environ | grep '^XAUTHORITY=' | cut -d= -f2)
DISP=$(tr '\0' '\n' </proc/$GS/environ | grep '^DISPLAY=' | cut -d= -f2)
DISPLAY=$DISP XAUTHORITY=$XA xhost +local: >/dev/null 2>&1 || true

sudo docker image inspect "$IMAGE" >/dev/null 2>&1 || IMAGE=ghcr.io/autowarefoundation/autoware:universe-cuda
sudo docker rm -f autoware >/dev/null 2>&1 || true
sudo docker run -d --name autoware --net host --gpus all \
  -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e DISPLAY="$DISP" -e XAUTHORITY=/root/.Xauthority \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw -v "$XA":/root/.Xauthority:ro \
  -v "$MAPS":/root/autoware_map:ro \
  "$IMAGE" sleep infinity
# carla client (if image isn't the baked one)
sudo docker exec autoware bash -lc "python3 -c 'import carla' 2>/dev/null || pip install -q carla==0.9.16"
echo "Launching Autoware e2e ($TOWN) — rviz will open on the monitor..."
sudo docker exec -d autoware bash -lc \
  "source /opt/autoware/setup.bash && ros2 launch autoware_launch e2e_simulator.launch.xml \
   map_path:=/root/autoware_map/$TOWN vehicle_model:=sample_vehicle \
   sensor_model:=carla_sensor_kit simulator_type:=carla carla_map:=$TOWN \
   > /tmp/e2e.log 2>&1"
echo "Started. Watch: sudo docker exec autoware tail -f /tmp/e2e.log"
