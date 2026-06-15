#!/bin/bash
# Host-side map-switch daemon: watches /tmp/roii_map_request (written by the
# gateway when the tablet requests a map) and runs the full bring-up for that
# town. Run once in a terminal:  ./run.sh mapdaemon
REPO="$(cd "$(dirname "$0")/.." && pwd)"
REQ=/tmp/roii_map_request
echo "[map-daemon] watching $REQ — tablet settings can now switch maps"
rm -f "$REQ"
while true; do
  if [ -f "$REQ" ]; then
    TOWN=$(cat "$REQ"); rm -f "$REQ"
    echo "[map-daemon] switching to $TOWN ..."
    bash "$REPO/scripts/run_localization_demo.sh" "$TOWN"
    echo "[map-daemon] $TOWN up — back to watching"
  fi
  sleep 3
done
