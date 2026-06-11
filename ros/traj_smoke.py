#!/usr/bin/env python3
"""Trajectory smoke test -- the REAL bring-up acceptance gate.

Sets one route to a goal ahead of the ego, waits for the planning pipeline to
produce a trajectory, then clears the route. Exit 0 = stack can plan; exit 1 =
the behavior/scenario chain is dead (poisoned respawn) -> caller restarts e2e.
Usage: python3 traj_smoke.py <lanelet_osm>
"""
import math
import re
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from nav_msgs.msg import Odometry
from geometry_msgs.msg import Pose
from autoware_planning_msgs.msg import Trajectory
from autoware_adapi_v1_msgs.srv import SetRoutePoints, ClearRoute


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
        cl = [((l[i][0] + r[i][0]) / 2, (l[i][1] + r[i][1]) / 2) for i in range(k)]
        for i in range(len(cl)):
            j = min(i + 1, len(cl) - 1)
            kk = max(i - 1, 0)
            pts.append((cl[i][0], cl[i][1],
                        math.atan2(cl[j][1] - cl[kk][1], cl[j][0] - cl[kk][0])))
    return pts


def main():
    pts = load_pts(sys.argv[1])
    rclpy.init()
    n = Node("traj_smoke")
    n.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
    box = {"traj": 0}
    n.create_subscription(Odometry, "/localization/kinematic_state",
                          lambda m: box.update(odom=m), 10)
    n.create_subscription(Trajectory, "/planning/scenario_planning/trajectory",
                          lambda m: box.update(traj=len(m.points)), 1)
    clr = n.create_client(ClearRoute, "/api/routing/clear_route")
    rte = n.create_client(SetRoutePoints, "/api/routing/set_route_points")

    def call(cli, req, tmo):
        fut = cli.call_async(req)
        t = time.time()
        while not fut.done() and time.time() - t < tmo:
            rclpy.spin_once(n, timeout_sec=0.1)
        return fut.result() if fut.done() else None

    t0 = time.time()
    while "odom" not in box and time.time() - t0 < 30:
        rclpy.spin_once(n, timeout_sec=0.2)
    if "odom" not in box:
        print("SMOKE: no odometry"); sys.exit(1)
    if not (rte.wait_for_service(timeout_sec=15) and clr.wait_for_service(timeout_sec=5)):
        print("SMOKE: routing services missing"); sys.exit(1)
    p = box["odom"].pose.pose
    ex, ey = p.position.x, p.position.y
    q = p.orientation
    eyaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
    cand = sorted((math.hypot(x - ex, y - ey), x, y, tg) for x, y, tg in pts
                  if 40 < math.hypot(x - ex, y - ey) < 90
                  and abs((math.atan2(y - ey, x - ex) - eyaw + math.pi) % (2 * math.pi) - math.pi) < 1.0)
    call(clr, ClearRoute.Request(), 5)
    ok = False
    for d, gx, gy, gtg in cand[len(cand) // 3: len(cand) // 3 + 3] + cand[:3]:
        for g2 in (gtg, gtg + math.pi):
            req = SetRoutePoints.Request()
            req.header.frame_id = "map"
            req.option.allow_goal_modification = True
            g = Pose()
            g.position.x, g.position.y = gx, gy
            g.orientation.z = math.sin(g2 / 2)
            g.orientation.w = math.cos(g2 / 2)
            req.goal = g
            r = call(rte, req, 10)
            if r and r.status.success:
                ok = True
                break
        if ok:
            break
    if not ok:
        print("SMOKE: no route"); sys.exit(1)
    t0 = time.time()
    while time.time() - t0 < 25:
        rclpy.spin_once(n, timeout_sec=0.2)
        if box["traj"] > 50:
            call(clr, ClearRoute.Request(), 5)
            print(f"SMOKE: OK trajectory {box['traj']} pts")
            sys.exit(0)
    call(clr, ClearRoute.Request(), 5)
    print("SMOKE: route set but NO trajectory (poisoned stack)")
    sys.exit(1)


if __name__ == "__main__":
    main()
