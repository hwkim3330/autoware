#!/usr/bin/env python3
"""Set ONE route to a known-good centerline goal and watch, in the same node,
whether /planning/mission_planning/route gets published and a trajectory appears.
Isolates: does a SUCCESSFUL set_route_points actually reach the planner?"""
import math, time, re
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy, HistoryPolicy
from nav_msgs.msg import Odometry
from geometry_msgs.msg import Pose
from autoware_adapi_v1_msgs.srv import SetRoutePoints, ClearRoute
from autoware_adapi_v1_msgs.msg import RouteState
from autoware_planning_msgs.msg import LaneletRoute, Trajectory

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
    rclpy.init(); n = Node("diag_life")
    n.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
    box = {"route_segs": -1, "traj": -1, "rstate": -1}
    n.create_subscription(Odometry, "/localization/kinematic_state", lambda m: box.__setitem__("odom", m), 10)
    tl = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                    reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
    n.create_subscription(LaneletRoute, "/planning/mission_planning/route",
                          lambda m: box.__setitem__("route_segs", len(m.segments)), tl)
    n.create_subscription(RouteState, "/api/routing/state",
                          lambda m: box.__setitem__("rstate", m.state), tl)
    n.create_subscription(Trajectory, "/planning/scenario_planning/trajectory",
                          lambda m: box.__setitem__("traj", len(m.points)), 1)
    clr = n.create_client(ClearRoute, "/api/routing/clear_route")
    rte = n.create_client(SetRoutePoints, "/api/routing/set_route_points")
    t0 = time.time()
    while "odom" not in box and time.time() - t0 < 15:
        rclpy.spin_once(n, timeout_sec=0.2)
    p = box["odom"].pose.pose; ex, ey = p.position.x, p.position.y; eyaw = yaw_of(p.orientation)
    rte.wait_for_service(timeout_sec=5); clr.wait_for_service(timeout_sec=5)
    print(f"EGO ({ex:.1f},{ey:.1f}) yaw={math.degrees(eyaw):.0f}")
    cand = sorted([(math.hypot(x-ex, y-ey), x, y, tg) for x, y, tg in pts
                   if 50 < math.hypot(x-ex, y-ey) < 80
                   and abs((math.atan2(y-ey, x-ex)-eyaw+math.pi) % (2*math.pi)-math.pi) < 0.9])
    fc = clr.call_async(ClearRoute.Request()); t = time.time()
    while not fc.done() and time.time()-t < 4: rclpy.spin_once(n, timeout_sec=0.1)
    ok = False
    for d, gx, gy, gtg in cand[:6]:
        req = SetRoutePoints.Request(); req.header.frame_id = "map"; req.option.allow_goal_modification = True
        g = Pose(); g.position.x, g.position.y = gx, gy
        g.orientation.z = math.sin(gtg/2); g.orientation.w = math.cos(gtg/2); req.goal = g
        fr = rte.call_async(req); t = time.time()
        while not fr.done() and time.time()-t < 14: rclpy.spin_once(n, timeout_sec=0.1)
        if fr.done() and fr.result().status.success:
            print(f"set_route SUCCESS -> goal ({gx:.0f},{gy:.0f}) d={d:.0f}m"); ok = True; break
        else:
            r = fr.result() if fr.done() else None
            print(f"  goal ({gx:.0f},{gy:.0f}): {'fail '+r.status.message if r else 'timeout'}")
    if not ok:
        print("no goal succeeded"); return
    # watch route/traj for 20 s
    for i in range(20):
        t = time.time()
        while time.time()-t < 1: rclpy.spin_once(n, timeout_sec=0.1)
        print(f"  +{i+1:2d}s  rstate={box['rstate']} route_segments={box['route_segs']} traj_points={box['traj']}")
    n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
