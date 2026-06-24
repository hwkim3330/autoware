#!/usr/bin/env python3
"""Seed the ego on a WELL-CONNECTED lanelet of a real map (planning_sim), via the
ADAPI initialize service, at the correct road elevation. Run after a real-map
bring-up so tap-to-go / drive works immediately (find_spawn tends to pick a
poorly-connected stub; raw /initialpose is ignored once the sim is initialized).

Usage (in container): python3 seed_realmap_start.py <site>
"""
import math, subprocess, sys
import lanelet2
from lanelet2.projection import UtmProjector
from lanelet2.io import Origin, loadRobust

site = sys.argv[1] if len(sys.argv) > 1 else "pangyo_ngii"
base = f"/root/autoware_map/{site}"
la, lo = [float(v) for v in open(f"{base}/{site}.origin").read().split()]
m, _ = loadRobust(f"{base}/lanelet2_map.osm", UtmProjector(Origin(la, lo)))
rules = lanelet2.traffic_rules.create(lanelet2.traffic_rules.Locations.Germany,
                                      lanelet2.traffic_rules.Participants.Vehicle)
g = lanelet2.routing.RoutingGraph(m, rules)


def sub(ll):
    try:
        return ll.attributes["subtype"]
    except Exception:
        return ""


def pt(p):
    a = p.attributes
    try:
        x = float(a["local_x"]); y = float(a["local_y"])  # a[key] -> str value
    except Exception:
        return None
    try:
        z = float(a["ele"])
    except Exception:
        z = 0.0
    return x, y, z


def center(ll):
    Lf = [pt(p) for p in ll.leftBound if pt(p)]
    R = [pt(p) for p in ll.rightBound if pt(p)]
    n = min(len(Lf), len(R))
    return [((Lf[i][0] + R[i][0]) / 2, (Lf[i][1] + R[i][1]) / 2,
             (Lf[i][2] + R[i][2]) / 2) for i in range(n)]


road = [ll for ll in m.laneletLayer if sub(ll) == "road"]
# sample (reachableSet over every lanelet is slow); take the best of a sample
sample = [ll for ll in road[::4] if len(center(ll)) >= 4]
start = max(sample, key=lambda ll: len(g.reachableSet(ll, 800.0, 0)))
c = center(start)
sx, sy, sz = c[0]
sx2, sy2, _ = c[3]
yaw = math.degrees(math.atan2(sy2 - sy, sx2 - sx))
qz, qw = math.sin(math.radians(yaw) / 2), math.cos(math.radians(yaw) / 2)
print(f"seed {site}: reach={len(g.reachableSet(start,1500.0,0))} at ({sx:.0f},{sy:.0f},z={sz:.1f})", flush=True)
subprocess.run(["bash", "-lc",
    "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; "
    f"ros2 service call /api/localization/initialize autoware_adapi_v1_msgs/srv/InitializeLocalization "
    f"'{{pose: [{{header: {{frame_id: map}}, pose: {{pose: {{position: {{x: {sx}, y: {sy}, z: {sz}}}, "
    f"orientation: {{z: {qz}, w: {qw}}}}}, covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, "
    f"0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.068]}}}}]}}'"], timeout=30)
print("seeded.", flush=True)
