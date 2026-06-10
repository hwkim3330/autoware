#!/bin/bash
# One-shot: native CARLA 0.9.16 -> Autoware (docker, rviz) -> tablet gateway.
# Run from the logged-in GNOME desktop (monitor on RTX 3090).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
TOWN="${1:-Town01}"

echo "############ 1/3  CARLA 0.9.16 ############"
"$HERE/start_carla_native.sh" 2000
echo "waiting for CARLA world (software-renders shaders on first run)..."
ready=0
for i in $(seq 1 60); do
  python3 -c "import carla; c=carla.Client('localhost',2000,worker_threads=1); c.set_timeout(10); c.get_world()" 2>/dev/null && { ready=1; break; }
  sleep 3
done
[ "$ready" -eq 1 ] || { echo "CARLA did not become ready on localhost:2000"; exit 1; }
echo "CARLA ready."

echo "############ 2/3  Autoware ($TOWN) + rviz ############"
"$HERE/start_autoware.sh" "$TOWN"

echo "############ 3/3  Tablet gateway (ws://0.0.0.0:8765) ############"
( cd "$HERE/../ros" && python3 -u carla_ws_gateway.py >/tmp/gateway.log 2>&1 ) &
echo "adb reverse for USB tablet:"; adb reverse tcp:8765 tcp:8765 2>/dev/null || true

cat <<EOF

All started.
  - rviz: on the monitor (set a 2D Goal Pose to make the ego drive)
  - Autoware log:  sudo docker exec autoware tail -f /tmp/e2e.log
  - tablet app:    USB_ADB mode  ws://127.0.0.1:8765/ws  (or WIFI ws://<PC-IP>:8765/ws)
EOF
