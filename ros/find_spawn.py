#!/usr/bin/env python3
"""Find a good on-lane spawn for a CARLA town from its lanelet2 osm.

- Parses centerlines (same logic as the gateway).
- Reports the nearest centerline to a given Autoware (x,y) -- to check if the
  current ego is on-lane.
- Picks a spawn on a long straight lane (lots of forward lane ahead) and prints
  the CARLA spawn string (y-flip, yaw-flip) so e2e can spawn the ego on-lane.

Usage:  python3 find_spawn.py <osm> [ego_x ego_y]
"""
import sys, math, re

osm = sys.argv[1]
txt = open(osm).read().replace("'", '"')  # JOSM exports use single quotes
nd = {}
for m in re.finditer(r'<node id="(-?\d+)"[^>]*>(.*?)</node>', txt, re.S):
    b = m.group(2)
    x = re.search(r'k="local_x" v="([-\d.]+)"', b)
    y = re.search(r'k="local_y" v="([-\d.]+)"', b)
    if x and y:
        nd[m.group(1)] = (float(x.group(1)), float(y.group(1)))

if not nd:
    # MGRS map (no local_x/local_y tags, e.g. Autoware sample real maps):
    # map-frame coords = UTM easting/northing mod 100 km (the MGRS square).
    import pyproj
    nodes = re.findall(r'<node id="(-?\d+)"[^>]*lat="(-?[\d.]+)" lon="(-?[\d.]+)"', txt)
    if nodes:
        lat0, lon0 = float(nodes[0][1]), float(nodes[0][2])
        zone = int((lon0 + 180) / 6) + 1
        epsg = (32600 if lat0 >= 0 else 32700) + zone
        tf = pyproj.Transformer.from_crs("EPSG:4326", f"EPSG:{epsg}", always_xy=True)
        for nid, lat, lon in nodes:
            e, n = tf.transform(float(lon), float(lat))
            nd[nid] = (e % 100000, n % 100000)
        print(f"(MGRS map: {len(nd)} nodes via UTM zone {zone})")
wy = {}
for m in re.finditer(r'<way id="(-?\d+)"[^>]*>(.*?)</way>', txt, re.S):
    refs = [r for r in re.findall(r'<nd ref="(-?\d+)"', m.group(2)) if r in nd]
    if refs:
        wy[m.group(1)] = [nd[r] for r in refs]
# centerline per lanelet, keep as polylines
lanes = []
for m in re.finditer(r'<relation id="(-?\d+)"[^>]*>(.*?)</relation>', txt, re.S):
    b = m.group(2)
    if 'v="lanelet"' not in b:
        continue
    L = re.search(r'ref="(-?\d+)" role="left"', b)
    R = re.search(r'ref="(-?\d+)" role="right"', b)
    if not (L and R and L.group(1) in wy and R.group(1) in wy):
        continue
    l, r = wy[L.group(1)], wy[R.group(1)]
    k = min(len(l), len(r))
    cl = [((l[i][0] + r[i][0]) / 2, (l[i][1] + r[i][1]) / 2) for i in range(k)]
    # orient by geometry: driving direction must keep the LEFT boundary on the
    # left (cross(dir, left-center) > 0); some osm store points reversed.
    if len(cl) >= 2:
        dx, dy = cl[1][0] - cl[0][0], cl[1][1] - cl[0][1]
        lx, ly = l[0][0] - cl[0][0], l[0][1] - cl[0][1]
        if dx * ly - dy * lx < 0:
            cl.reverse()
    if len(cl) >= 2:
        length = sum(math.hypot(cl[i + 1][0] - cl[i][0], cl[i + 1][1] - cl[i][1]) for i in range(len(cl) - 1))
        lanes.append((m.group(1), cl, length))

allpts = [(p[0], p[1]) for _, cl, _ in lanes for p in cl]
print(f"{len(lanes)} lanelets, {len(allpts)} centerline pts")

if len(sys.argv) >= 4:
    ex, ey = float(sys.argv[2]), float(sys.argv[3])
    best = min(allpts, key=lambda q: math.hypot(q[0] - ex, q[1] - ey))
    d = math.hypot(best[0] - ex, best[1] - ey)
    print(f"EGO ({ex:.1f},{ey:.1f}) nearest centerline ({best[0]:.1f},{best[1]:.1f}) dist={d:.1f}m "
          f"{'ON-LANE' if d < 2.5 else 'OFF-LANE -- this is why route is empty'}")

# pick spawn: candidates at ~10% into the longest lanes, BOTH orientations
# (left/right roles are swapped in some converted maps, so geometry alone can
# lie). Validate each by what the gateway's drive actually needs: centerline
# points 40-90 m AHEAD within ~57 deg of the heading. Most ahead-points wins.
def ahead_count(ax, ay, yaw):
    n = 0
    for x, y in allpts:
        d = math.hypot(x - ax, y - ay)
        if 40 < d < 90:
            ang = math.atan2(y - ay, x - ax)
            if abs((ang - yaw + math.pi) % (2 * math.pi) - math.pi) < 1.0:
                n += 1
    return n

lanes.sort(key=lambda t: -t[2])
best = None
for lid, cl, length in lanes[:10]:
    i = max(1, len(cl) // 10)
    ax, ay = cl[i]
    nx, ny = cl[min(i + 1, len(cl) - 1)]
    yaw = math.atan2(ny - ay, nx - ax)
    for y2 in (yaw, yaw + math.pi):   # try both orientations
        score = ahead_count(ax, ay, y2)
        if best is None or score > best[0]:
            best = (score, lid, length, ax, ay, y2)

score, lid, length, ax, ay, aw_yaw = best
# Autoware -> CARLA: cx=ax, cy=-ay, cyaw_deg = -deg(aw_yaw)
cx, cy = ax, -ay
cyaw = -math.degrees(aw_yaw)
print(f"BEST SPAWN  lanelet {lid} len={length:.0f}m aheadPts={score}")
print(f"  Autoware on-lane (x,y,yaw) = ({ax:.1f}, {ay:.1f}, {math.degrees(aw_yaw):.0f}deg)")
print(f"  CARLA spawn_point = \"{cx:.1f}, {cy:.1f}, 0.5, 0.0, 0.0, {cyaw:.1f}\"")
