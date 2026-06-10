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
txt = open(osm).read()
nd = {}
for m in re.finditer(r'<node id="(-?\d+)"[^>]*>(.*?)</node>', txt, re.S):
    b = m.group(2)
    x = re.search(r'k="local_x" v="([-\d.]+)"', b)
    y = re.search(r'k="local_y" v="([-\d.]+)"', b)
    if x and y:
        nd[m.group(1)] = (float(x.group(1)), float(y.group(1)))
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

# pick spawn: a point ~10% into the LONGEST lane, heading along the lane
lanes.sort(key=lambda t: -t[2])
lid, cl, length = lanes[0]
i = max(1, len(cl) // 10)
ax, ay = cl[i]
nx, ny = cl[min(i + 1, len(cl) - 1)]
aw_yaw = math.atan2(ny - ay, nx - ax)
# Autoware -> CARLA: cx=ax, cy=-ay, cyaw_deg = -deg(aw_yaw)
cx, cy = ax, -ay
cyaw = -math.degrees(aw_yaw)
print(f"BEST SPAWN  lanelet {lid} len={length:.0f}m")
print(f"  Autoware on-lane (x,y,yaw) = ({ax:.1f}, {ay:.1f}, {math.degrees(aw_yaw):.0f}deg)")
print(f"  CARLA spawn_point = \"{cx:.1f}, {cy:.1f}, 0.5, 0.0, 0.0, {cyaw:.1f}\"")
