#!/bin/bash
# ============================================================================
# Real-map demo: OSM (숭실대/판교/K-City) -> CARLA OpenDRIVE world + Autoware
# GNSS localization + tablet app. No pointcloud map needed -- the CARLA interface
# publishes a ground-truth-accurate GNSS pose (carla_ros.py) which the Niro GNSS
# pipeline (gnss_only_localizer.py) feeds straight to the EKF.
#
# Pipeline producing the inputs (run these first, they're offline):
#   python3 scripts/osm_to_carla.py   <site>   -> ~/autoware_map/osm/<site>.xodr
#   python3 scripts/osm_to_lanelet2.py <site>  -> ~/autoware_map/<site>/{lanelet2_map.osm,...}
#
# Usage: run_osm_demo.sh soongsil|pangyo|kcity
# ============================================================================
set -u
SITE="${1:-soongsil}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CARLA_DIR=/opt/carla-simulator/CarlaUE4/Binaries/Linux
BOOT_TOWN=Town01    # CARLA boots a light town; the interface then generates the
                    # OpenDRIVE world from <site>.xodr (patched carla_autoware.py).
DISP="${DISP:-:1}"; XA="${XA:-/home/kim/.Xauthority}"
SUDO() { timeout 180 sudo -S "$@" < <(echo 1); }
DEX() { SUDO docker exec autoware bash -lc "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; $1"; }

XODR="$HOME/autoware_map/osm/$SITE.xodr"
MAPDIR="$HOME/autoware_map/$SITE"
[ -f "$XODR" ] || { echo "missing $XODR -- run: python3 scripts/osm_to_carla.py $SITE"; exit 1; }
[ -f "$MAPDIR/lanelet2_map.osm" ] || { echo "missing $MAPDIR -- run: python3 scripts/osm_to_lanelet2.py $SITE"; exit 1; }

echo "==> Real-map demo: $SITE  (xodr=$(basename "$XODR"), $(grep -c '<road ' "$XODR") roads)"

echo "==> [1/5] Boot a fresh CARLA ($BOOT_TOWN; interface will load the OpenDRIVE)"
SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
booted=0
for attempt in 1 2 3 4 5; do
  cd "$CARLA_DIR"
  setsid env DISPLAY="$DISP" XAUTHORITY="$XA" \
    ./CarlaUE4-Linux-Shipping "$BOOT_TOWN" -RenderOffScreen -quality-level=Low \
    -nosound -carla-rpc-port=2000 </dev/null >/tmp/carla.log 2>&1 & disown
  for i in $(seq 1 25); do sleep 3; ss -tlnp 2>/dev/null | grep -q :2000 && break; done
  sleep 15; ss -tlnp 2>/dev/null | grep -q :2000 && { echo "    CARLA up (attempt $attempt)"; booted=1; break; }
  echo "    boot crashed, retry"; SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null; sleep 4
done
[ $booted = 1 ] || { echo "CARLA failed to boot"; exit 1; }

echo "==> [2/5] Stage maps + patched interface + GNSS localizer into the container"
SUDO docker start autoware >/dev/null 2>&1
# real-map artifacts
SUDO docker exec autoware bash -lc "mkdir -p /root/autoware_map/$SITE /root/autoware_map/osm" >/dev/null 2>&1
SUDO docker cp "$XODR" autoware:/root/autoware_map/osm/$SITE.xodr >/dev/null 2>&1
for f in lanelet2_map.osm map_projector_info.yaml pointcloud_map.pcd; do
  SUDO docker cp "$MAPDIR/$f" autoware:/root/autoware_map/$SITE/$f >/dev/null 2>&1
done
# patched carla_autoware.py: load_world() handles a .xodr path
SUDO docker cp "$REPO/container_patches/carla_autoware.py" \
  autoware:/opt/autoware/lib/python3.10/site-packages/autoware_carla_interface/carla_autoware.py >/dev/null 2>&1
for f in ros_ws_gateway.py gnss_only_localizer.py perception_stub.py traffic_light_stub.py traj_smoke.py find_spawn.py; do
  [ -f "$REPO/ros/$f" ] && SUDO docker cp "$REPO/ros/$f" autoware:/root/$f >/dev/null 2>&1
done

echo "==> [3/5] Clean ROS (container stop+start) + EKF<-GNSS remap + diag relax"
SUDO docker stop -t 5 autoware >/dev/null 2>&1; SUDO docker start autoware >/dev/null 2>&1; sleep 6
# EKF subscribes the multimode pose (gnss_only_localizer feeds it the GNSS pose)
PTF=/opt/autoware/share/autoware_launch/launch/components/tier4_localization_component.launch.xml
SUDO docker exec autoware bash -lc \
  "sed -i 's|value=\"/localization/pose_estimator/pose_with_covariance\"|value=\"/localization/multimode/pose_with_covariance\"|' $PTF" >/dev/null 2>&1 || true
# interface spawns at a random valid OpenDRIVE location (no baked Town spawn)
SUDO docker exec autoware bash -lc \
  "sed -i 's|name=\"spawn_point\" default=\"[^\"]*\"|name=\"spawn_point\" default=\"None\"|' \
   /opt/autoware/share/autoware_carla_interface/autoware_carla_interface.launch.xml" >/dev/null 2>&1 || true
# relax localization diags that gate autonomous (accuracy/sensor_fusion + the
# wedge-prone map->base_link transform monitor) -- GNSS localization is healthy.
for Y in localization.yaml autoware-carla.yaml; do
  P=/opt/autoware/share/autoware_launch/config/system/diagnostics/$Y
  SUDO docker exec autoware bash -lc \
    "sed -i '/link: \/autoware\/localization\/accuracy }/d; /link: \/autoware\/localization\/sensor_fusion_status }/d' $P" >/dev/null 2>&1 || true
done
SUDO docker exec autoware bash -lc \
  "sed -i '\#path: /autoware/localization/topic_rate_check/transform#,/name: localization_topic_status/d' \
   /opt/autoware/share/autoware_launch/config/system/diagnostics/localization.yaml" >/dev/null 2>&1 || true

echo "==> [4/5] Launch Autoware e2e on the $SITE map (carla_map=<.xodr>, GNSS loc)"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash && \
   ros2 launch autoware_launch e2e_simulator.launch.xml \
   map_path:=/root/autoware_map/$SITE vehicle_model:=sample_vehicle \
   sensor_model:=carla_sensor_kit simulator_type:=carla carla_map:=/root/autoware_map/osm/$SITE.xodr \
   timeout:=300 perception:=false rviz:=false launch_system_monitor:=false \
   > /tmp/e2e.log 2>&1"
echo "    waiting for the world + interface to come up (90s)"; sleep 90

echo "==> [5/5] GNSS localizer + perception stub + traffic-light stub + gateway"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; python3 -u /root/gnss_only_localizer.py --ros-args -p use_sim_time:=true > /tmp/gnss_loc.log 2>&1"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; python3 -u /root/perception_stub.py --ros-args -p use_sim_time:=true > /tmp/pstub.log 2>&1"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; python3 -u /root/traffic_light_stub.py --ros-args -p use_sim_time:=true > /tmp/tlstub.log 2>&1"
SUDO docker exec -d autoware bash -lc \
  "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export LANELET_OSM=/root/autoware_map/$SITE/lanelet2_map.osm; export RVIZ_DISPLAY=$DISP; source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
for i in $(seq 1 30); do SUDO docker exec autoware bash -lc "ss -tlnp 2>/dev/null | grep -q 8765" && { echo "    gateway up (ws:8765)"; break; }; sleep 2; done
command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1 || true

echo "==> Done. Real-map ($SITE) stack up. Localization=GNSS (no PCD)."
echo "    Check: docker exec autoware tail -f /tmp/e2e.log   |  GNSS: /tmp/gnss_loc.log"
echo "    Drive from the tablet (tap-to-drive / MANUAL). rviz on the monitor."
