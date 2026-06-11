#!/usr/bin/env python3
"""Generate a VALIDATED per-town spawn table for run_localization_demo.sh.

For each town: load the world in CARLA, take CARLA's own get_spawn_points()
(guaranteed collision-free), convert to Autoware frame (y-flip), and score each
by how many lanelet centerline points lie 40-90 m AHEAD within ~57 deg of the
spawn heading (what the gateway's drive goal-search needs). Highest score wins.

Run on the HOST with CARLA up (or it boots towns one by one on a running server):
    python3 scripts/gen_spawn_table.py [Town01 Town03 ...]
"""
import math, re, sys

import carla

MAPS = "/home/kim/autoware_map"


def load_pts(path):
    txt = open(path).read().replace("'", '"')
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
    pts = []
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
        pts += [((l[i][0] + r[i][0]) / 2, (l[i][1] + r[i][1]) / 2) for i in range(k)]
    return pts


def ahead_count(pts, ax, ay, yaw):
    n = 0
    for x, y in pts:
        d = math.hypot(x - ax, y - ay)
        if 40 < d < 90:
            ang = math.atan2(y - ay, x - ax)
            if abs((ang - yaw + math.pi) % (2 * math.pi) - math.pi) < 1.0:
                n += 1
    return n


def main():
    towns = sys.argv[1:] or ["Town01", "Town02", "Town03", "Town04", "Town05", "Town10HD"]
    client = carla.Client("localhost", 2000)
    client.set_timeout(180.0)
    for town in towns:
        try:
            pts = load_pts(f"{MAPS}/{town}/lanelet2_map.osm")
            world = client.load_world(town)
            sps = world.get_map().get_spawn_points()
        except Exception as e:
            print(f"{town}: ERROR {e}")
            continue
        best = None
        for sp in sps:
            # CARLA -> Autoware: ax = cx, ay = -cy, ayaw = -cyaw
            ax, ay = sp.location.x, -sp.location.y
            ayaw = -math.radians(sp.rotation.yaw)
            score = ahead_count(pts, ax, ay, ayaw)
            if best is None or score > best[0]:
                best = (score, sp)
        score, sp = best
        print(f'  {town})   SPAWN="{sp.location.x:.1f}, {sp.location.y:.1f}, '
              f'{sp.location.z + 0.3:.1f}, 0.0, 0.0, {sp.rotation.yaw:.1f}" ;;  # aheadPts={score}')


if __name__ == "__main__":
    main()
