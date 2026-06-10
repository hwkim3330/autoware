#!/usr/bin/env python3
"""One-shot routing diagnostic. Run INSIDE the container.

Reads current ego pose from TF/odom, prints it, then tries set_route_points to a
goal N metres straight ahead on the ego heading -- bypassing the gateway's
centerline search -- to isolate whether the mission planner itself can route on
this map, or whether the gateway's goal picking is the problem.
"""
import sys, math, time
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from nav_msgs.msg import Odometry
from geometry_msgs.msg import Pose
from autoware_adapi_v1_msgs.srv import SetRoutePoints, ClearRoute
from autoware_adapi_v1_msgs.msg import RouteState


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def main():
    rclpy.init()
    n = Node("diag_route")
    n.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
    box = {}
    n.create_subscription(Odometry, "/localization/kinematic_state",
                          lambda m: box.__setitem__("odom", m), 10)
    n.create_subscription(RouteState, "/api/routing/state",
                          lambda m: box.__setitem__("rs", m.state), 1)
    cli_clear = n.create_client(ClearRoute, "/api/routing/clear_route")
    cli_route = n.create_client(SetRoutePoints, "/api/routing/set_route_points")
    t0 = time.time()
    while "odom" not in box and time.time() - t0 < 15:
        rclpy.spin_once(n, timeout_sec=0.2)
    if "odom" not in box:
        print("NO ODOM -- not localized"); return
    p = box["odom"].pose.pose
    ex, ey = p.position.x, p.position.y
    eyaw = yaw_of(p.orientation)
    print(f"EGO  x={ex:.1f} y={ey:.1f} yaw={math.degrees(eyaw):.0f}deg  route_state={box.get('rs')}")
    print(f"clients: clear={cli_clear.wait_for_service(timeout_sec=5)} route={cli_route.wait_for_service(timeout_sec=5)}")

    for dist in (30, 50, 80, 120):
        gx = ex + dist * math.cos(eyaw)
        gy = ey + dist * math.sin(eyaw)
        # clear first
        fc = cli_clear.call_async(ClearRoute.Request())
        t = time.time()
        while not fc.done() and time.time() - t < 4:
            rclpy.spin_once(n, timeout_sec=0.1)
        req = SetRoutePoints.Request()
        req.header.frame_id = "map"
        req.option.allow_goal_modification = True
        g = Pose()
        g.position.x, g.position.y = gx, gy
        g.orientation = p.orientation
        req.goal = g
        fr = cli_route.call_async(req)
        t = time.time()
        while not fr.done() and time.time() - t < 8:
            rclpy.spin_once(n, timeout_sec=0.1)
        if fr.done():
            r = fr.result()
            print(f"  goal +{dist}m ({gx:.0f},{gy:.0f}): success={r.status.success} code={r.status.code} msg='{r.status.message}'")
        else:
            print(f"  goal +{dist}m ({gx:.0f},{gy:.0f}): TIMEOUT (no service response in 8s)")
    n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
