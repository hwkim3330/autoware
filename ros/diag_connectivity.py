#!/usr/bin/env python3
"""Test lanelet routing connectivity. Run INSIDE the container.

Routes to REAL centerline points at increasing distance ahead of the ego. If
short (same-lanelet) goals succeed but longer (cross-lanelet) goals fail with
'route empty', the lanelet map lacks predecessor/successor connectivity.
"""
import sys, math, time, re
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from nav_msgs.msg import Odometry
from geometry_msgs.msg import Pose
from autoware_adapi_v1_msgs.srv import SetRoutePoints, ClearRoute

OSM = "/root/autoware_map/Town04/lanelet2_map.osm"


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def load_pts(path):
    txt = open(path).read()
    nd = {}
    for m in re.finditer(r'<node id="(-?\d+)"[^>]*>(.*?)</node>', txt, re.S):
        b = m.group(2)
        x = re.search(r'k="local_x" v="([-\d.]+)"', b); y = re.search(r'k="local_y" v="([-\d.]+)"', b)
        if x and y: nd[m.group(1)] = (float(x.group(1)), float(y.group(1)))
    wy = {}
    for m in re.finditer(r'<way id="(-?\d+)"[^>]*>(.*?)</way>', txt, re.S):
        refs = [r for r in re.findall(r'<nd ref="(-?\d+)"', m.group(2)) if r in nd]
        if refs: wy[m.group(1)] = [nd[r] for r in refs]
    pts = []
    for m in re.finditer(r'<relation id="(-?\d+)"[^>]*>(.*?)</relation>', txt, re.S):
        b = m.group(2)
        if 'v="lanelet"' not in b: continue
        L = re.search(r'ref="(-?\d+)" role="left"', b); R = re.search(r'ref="(-?\d+)" role="right"', b)
        if not (L and R and L.group(1) in wy and R.group(1) in wy): continue
        l, r = wy[L.group(1)], wy[R.group(1)]
        k = min(len(l), len(r))
        cl = [((l[i][0] + r[i][0]) / 2, (l[i][1] + r[i][1]) / 2) for i in range(k)]
        for i in range(len(cl)):
            j = min(i + 1, len(cl) - 1); kk = max(i - 1, 0)
            tg = math.atan2(cl[j][1] - cl[kk][1], cl[j][0] - cl[kk][0])
            pts.append((cl[i][0], cl[i][1], tg))
    return pts


def main():
    pts = load_pts(OSM)
    rclpy.init(); n = Node("diag_conn")
    n.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
    box = {}
    n.create_subscription(Odometry, "/localization/kinematic_state", lambda m: box.__setitem__("odom", m), 10)
    clr = n.create_client(ClearRoute, "/api/routing/clear_route")
    rte = n.create_client(SetRoutePoints, "/api/routing/set_route_points")
    t0 = time.time()
    while "odom" not in box and time.time() - t0 < 15:
        rclpy.spin_once(n, timeout_sec=0.2)
    p = box["odom"].pose.pose; ex, ey = p.position.x, p.position.y; eyaw = yaw_of(p.orientation)
    rte.wait_for_service(timeout_sec=5); clr.wait_for_service(timeout_sec=5)
    print(f"EGO ({ex:.1f},{ey:.1f}) yaw={math.degrees(eyaw):.0f}")
    # real centerline points ahead, sorted by distance
    cand = []
    for x, y, tg in pts:
        d = math.hypot(x - ex, y - ey)
        ang = math.atan2(y - ey, x - ex)
        if d > 3 and abs((ang - eyaw + math.pi) % (2 * math.pi) - math.pi) < 1.0:
            cand.append((d, x, y, tg))
    cand.sort()
    tried = set()
    for d, gx, gy, gtg in cand:
        bucket = int(d // 10)
        if bucket in tried: continue
        tried.add(bucket)
        fc = clr.call_async(ClearRoute.Request()); t = time.time()
        while not fc.done() and time.time() - t < 4: rclpy.spin_once(n, timeout_sec=0.1)
        req = SetRoutePoints.Request(); req.header.frame_id = "map"; req.option.allow_goal_modification = True
        g = Pose(); g.position.x, g.position.y = gx, gy
        g.orientation.z = math.sin(gtg / 2); g.orientation.w = math.cos(gtg / 2)
        req.goal = g
        fr = rte.call_async(req); t = time.time()
        while not fr.done() and time.time() - t < 10: rclpy.spin_once(n, timeout_sec=0.1)
        if fr.done():
            r = fr.result()
            print(f"  +{d:5.0f}m ({gx:.0f},{gy:.0f}): success={r.status.success} msg='{r.status.message}'")
        else:
            print(f"  +{d:5.0f}m ({gx:.0f},{gy:.0f}): TIMEOUT>10s")
        if len(tried) >= 8: break
    n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
