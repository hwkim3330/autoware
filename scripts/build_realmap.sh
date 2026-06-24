#!/usr/bin/env bash
# Build an Autoware-ready, ROUTABLE lanelet2 map for a real location, end to end:
#   OSM (Overpass) -> OpenDRIVE (CARLA Osm2Odr) -> lanelet2 (crdesigner) ->
#   reproject WGS84->local + projector + dummy PCD + origin.
# This is the pipeline that actually drives in Autoware (crdesigner gives a
# connected routing graph, unlike the hand OSM converter). Output: ~/autoware_map/<site>/
#
# Usage: build_realmap.sh <site> [radius_m]      e.g. build_realmap.sh pangyo 1200
set -e
SITE="${1:-pangyo}"; RADIUS="${2:-1200}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENV=/home/kim/.venv_crd/bin/python
OSMDIR="$HOME/autoware_map/osm"; OUT="$HOME/autoware_map/$SITE"
mkdir -p "$OUT"

echo "==> [1/4] OSM -> OpenDRIVE ($SITE, r=${RADIUS}m)"
python3 "$REPO/scripts/osm_to_carla.py" "$SITE" --radius "$RADIUS" 2>&1 | grep -E "OSM saved|OpenDRIVE saved|roads|DONE"

echo "==> [2/4] OpenDRIVE -> lanelet2 (crdesigner)"
"$VENV" - "$OSMDIR/$SITE.xodr" "$OUT/_crd.osm" <<'PY'
import sys
from crdesigner.map_conversion.map_conversion_interface import opendrive_to_lanelet
opendrive_to_lanelet(sys.argv[1], sys.argv[2])
print("crdesigner: converted")
PY

echo "==> [3/4] reproject WGS84 -> local_x/local_y + projector + origin"
python3 - "$OUT/_crd.osm" "$OUT" "$SITE" <<'PY'
import sys, math, os
import xml.etree.ElementTree as ET
inp, out, site = sys.argv[1], sys.argv[2], sys.argv[3]
t = ET.parse(inp); r = t.getroot()
nodes = r.findall("node")
lats=[float(n.get("lat")) for n in nodes]; lons=[float(n.get("lon")) for n in nodes]
lat0=sum(lats)/len(lats); lon0=sum(lons)/len(lons); R=6378137.0
for n in nodes:
    la,lo=float(n.get("lat")),float(n.get("lon"))
    x=math.radians(lo-lon0)*R*math.cos(math.radians(lat0)); y=math.radians(la-lat0)*R
    for k,v in (("local_x",f"{x:.3f}"),("local_y",f"{y:.3f}"),("ele","0")):
        ET.SubElement(n,"tag",{"k":k,"v":v})
t.write(out+"/lanelet2_map.osm", encoding="utf-8", xml_declaration=True)
open(out+"/map_projector_info.yaml","w").write("projector_type: local\n")
open(out+"/"+site+".origin","w").write(f"{lat0:.7f} {lon0:.7f}\n")
with open(out+"/pointcloud_map.pcd","w") as f:
    f.write("# .PCD v0.7\nVERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\nWIDTH 1\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS 1\nDATA ascii\n0 0 0\n")
print(f"lanelets nodes={len(nodes)} origin={lat0:.6f},{lon0:.6f}")
PY
rm -f "$OUT/_crd.osm"

echo "==> [4/4] stage into the autoware container"
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
SUDO docker exec autoware bash -lc "mkdir -p /root/autoware_map/$SITE" >/dev/null 2>&1
for f in lanelet2_map.osm map_projector_info.yaml pointcloud_map.pcd "$SITE.origin"; do
  SUDO docker cp "$OUT/$f" autoware:/root/autoware_map/$SITE/"$f" >/dev/null 2>&1
done
echo "DONE. map at $OUT  (drive: ./run.sh realdrive $SITE)"
