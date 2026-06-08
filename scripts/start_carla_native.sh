#!/bin/bash
# Start native CARLA 0.9.16 on the RTX 3090 (driver 535) inside the logged-in
# GNOME Xorg session. Requires you to be logged into the desktop (monitor on the
# RTX 3090). Headless render (-RenderOffScreen), RPC on :2000.
set -e
CARLA_ROOT="${CARLA_ROOT:-/opt/carla-simulator}"
PORT="${1:-2000}"

# Pull DISPLAY/XAUTHORITY from the running gnome-shell (the GPU desktop session).
GS=$(pgrep -x gnome-shell | head -1)
if [ -z "$GS" ]; then
  echo "No GNOME session found. Log into the desktop (monitor on the RTX 3090) first."
  exit 1
fi
export DISPLAY=$(tr '\0' '\n' </proc/$GS/environ | grep '^DISPLAY=' | cut -d= -f2)
export XAUTHORITY=$(tr '\0' '\n' </proc/$GS/environ | grep '^XAUTHORITY=' | cut -d= -f2)

pkill -9 -x "CarlaUE4-Linux-" 2>/dev/null || true
sleep 1
echo "Starting CARLA 0.9.16 (DISPLAY=$DISPLAY) on port $PORT ..."
cd "$CARLA_ROOT/CarlaUE4/Binaries/Linux"
setsid ./CarlaUE4-Linux-Shipping CarlaUE4 -RenderOffScreen -quality-level=Epic \
  -nosound -carla-rpc-port="$PORT" </dev/null >/tmp/carla_native.log 2>&1 &
disown
echo "Launched. Wait ~30s, then: python3 -c \"import carla; print(carla.Client('localhost',$PORT).get_world().get_map().name)\""
