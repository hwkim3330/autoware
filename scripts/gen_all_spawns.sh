#!/bin/bash
# Boot CARLA directly into each town (pinned cores, no runtime load_world) and
# generate a validated CARLA-safe spawn for it. Emits one table line per town.
set -u
TOWNS=${1:-"Town03 Town05 Town06 Town07"}
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
GS=$(pgrep -x gnome-shell | head -1)
DISP=$(tr '\0' '\n' </proc/$GS/environ 2>/dev/null | grep '^DISPLAY=' | cut -d= -f2)
XA=$(tr '\0' '\n' </proc/$GS/environ 2>/dev/null | grep '^XAUTHORITY=' | cut -d= -f2)
: "${DISP:=:1}"; : "${XA:=/run/user/1000/gdm/Xauthority}"

for TOWN in $TOWNS; do
  SUDO pkill -9 -f CarlaUE4-Linux-Shipping; sleep 4
  ok=0
  for attempt in 1 2 3; do
    cd /opt/carla-simulator/CarlaUE4/Binaries/Linux
    setsid taskset -c 0,8 env DISPLAY="$DISP" XAUTHORITY="$XA" \
      ./CarlaUE4-Linux-Shipping "$TOWN" -RenderOffScreen -quality-level=Low \
      -nosound -carla-rpc-port=2000 </dev/null >/tmp/carla.log 2>&1 & disown
    for i in $(seq 1 40); do sleep 3; ss -tlnp 2>/dev/null | grep -q :2000 && { ok=1; break; }; done
    [ $ok -eq 1 ] && break
    echo "# $TOWN boot crashed (attempt $attempt)"
    SUDO pkill -9 -f CarlaUE4-Linux-Shipping; sleep 4
  done
  if [ $ok -eq 0 ]; then echo "  ${TOWN})   # BOOT FAILED" ; continue; fi
  sleep 8
  python3 "$REPO/scripts/gen_spawn_table.py" "$TOWN" 2>/dev/null | grep -E "SPAWN|ERROR"
done
SUDO pkill -9 -f CarlaUE4-Linux-Shipping
echo "# done"
