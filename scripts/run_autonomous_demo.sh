#!/bin/bash
# Autonomous variant of run_localization_demo.sh: perception ON (lidar-based,
# cameras off in the sensor kit) so behavior planning gets real objects/occupancy
# -> trajectory -> drive. CPU partition keeps CARLA (cores 0-5) safe.
set -u
TOWN="${1:-Town01}"
CARLA_DIR=/opt/carla-simulator/CarlaUE4/Binaries/Linux
SUDO(){ echo 1 | sudo -S "$@"; }
GS=$(pgrep -x gnome-shell|head -1)
DISP=$(tr '\0' '\n' </proc/$GS/environ|grep '^DISPLAY='|cut -d= -f2); : "${DISP:=:1}"
XA=$(tr '\0' '\n' </proc/$GS/environ|grep '^XAUTHORITY='|cut -d= -f2); : "${XA:=/run/user/1000/gdm/Xauthority}"

echo "==> kill perception stub (real perception will replace it)"
SUDO docker exec autoware bash -lc "pkill -9 -f perception_stub 2>/dev/null; true"

echo "==> [1/4] Boot CARLA on cores 0-5"
SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
for a in 1 2 3 4 5; do
  cd "$CARLA_DIR"
  setsid taskset -c 0-5 env DISPLAY="$DISP" XAUTHORITY="$XA" \
    ./CarlaUE4-Linux-Shipping CarlaUE4 -RenderOffScreen -quality-level=Low -nosound \
    -carla-rpc-port=2000 </dev/null >/tmp/carla.log 2>&1 & disown
  up=0; for i in $(seq 1 25); do sleep 3; ss -tlnp 2>/dev/null|grep -q :2000 && { up=1; break; }; done
  if [ "${up:-0}" = 1 ]; then sleep 15; ss -tlnp 2>/dev/null|grep -q :2000 && { echo "  CARLA up (try $a)"; break; }; fi
  SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
done
ss -tlnp 2>/dev/null|grep -q :2000 || { echo "CARLA boot failed"; exit 1; }
SUDO renice -n -10 -p "$(pgrep -f CarlaUE4-Linux-Shipping|head -1)" >/dev/null 2>&1

echo "==> [2/4] clean container (cpuset 6-15)"
SUDO docker update --cpuset-cpus="6-15" autoware >/dev/null 2>&1
SUDO docker stop autoware >/dev/null 2>&1; SUDO docker start autoware >/dev/null 2>&1; sleep 6

echo "==> [3/4] launch e2e with PERCEPTION ON (cameras off in kit)"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash && \
   ros2 launch autoware_launch e2e_simulator.launch.xml map_path:=/root/autoware_map/$TOWN \
   vehicle_model:=sample_vehicle sensor_model:=carla_sensor_kit simulator_type:=carla \
   carla_map:=$TOWN timeout:=120 perception:=true rviz:=false launch_system_monitor:=false \
   > /tmp/e2e.log 2>&1"

echo "==> [4/4] settle 110s, report"
sleep 110
SUDO docker exec autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
   echo -n 'TF: '; timeout 8 ros2 run tf2_ros tf2_echo map base_link 2>/dev/null|grep -m1 Translation; \
   echo -n 'objects Hz: '; timeout 8 ros2 topic hz /perception/object_recognition/objects 2>/dev/null|grep -m1 average; \
   echo -n 'trajectory Hz: '; timeout 8 ros2 topic hz /planning/scenario_planning/trajectory 2>/dev/null|grep -m1 average||echo none"
echo "CARLA: $(ss -tlnp 2>/dev/null|grep -q :2000 && echo UP || echo DOWN)  load: $(cut -d' ' -f1-3 /proc/loadavg)"
