#!/bin/bash
# Host-side map-switch daemon. The gateway runs INSIDE the container and writes
# /tmp/roii_map_request there when the tablet requests a map. The container's
# /tmp is not shared and the autoware_map mount is read-only, so we read the
# request through `docker exec` (always works) and clear it. Run once in a
# terminal:  ./run.sh mapdaemon
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
CREQ=/tmp/roii_map_request                 # path inside the container
HREQ=/tmp/roii_map_request_host            # optional host-side manual trigger
echo "[map-daemon] watching container:$CREQ (via docker exec) — tablet map selector now switches maps"
SUDO docker exec autoware bash -c "rm -f $CREQ" 2>/dev/null
rm -f "$HREQ"
while true; do
  TOWN=$(SUDO docker exec autoware bash -c "cat $CREQ 2>/dev/null; rm -f $CREQ" 2>/dev/null | tr -dc 'A-Za-z0-9')
  [ -z "$TOWN" ] && [ -f "$HREQ" ] && { TOWN=$(tr -dc 'A-Za-z0-9' < "$HREQ"); rm -f "$HREQ"; }
  if [ -n "$TOWN" ]; then
    echo "[map-daemon] switching to $TOWN ..."
    bash "$REPO/scripts/run_localization_demo.sh" "$TOWN"
    echo "[map-daemon] $TOWN up — back to watching"
  fi
  sleep 3
done
