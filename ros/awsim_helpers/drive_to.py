#!/usr/bin/env python3
"""Click-to-drive: given a target (map-local x y), find the nearest lanelet + the lane DIRECTION
there (the orientation that makes Autoware routing succeed), set the route, and engage autonomous.
Usage: drive_to.py <x> <y>            (run with ROS_DISCOVERY_SERVER set)
"""
import sys, math, xml.etree.ElementTree as ET, time
import rclpy
from rclpy.node import Node
from autoware_adapi_v1_msgs.srv import SetRoutePoints, ChangeOperationMode, ClearRoute

MAP = "/root/autoware_map/shinjuku/lanelet2_map.osm"

def load_ways():
    t = ET.parse(MAP); r = t.getroot()
    nodes = {}
    for nd in r.findall('node'):
        lx = ly = None
        for tag in nd.findall('tag'):
            if tag.get('k') == 'local_x': lx = float(tag.get('v'))
            if tag.get('k') == 'local_y': ly = float(tag.get('v'))
        if lx is not None and ly is not None:
            nodes[nd.get('id')] = (lx, ly)
    ways = []
    for w in r.findall('way'):
        seq = [nodes[nd.get('ref')] for nd in w.findall('nd') if nd.get('ref') in nodes]
        if len(seq) >= 2: ways.append(seq)
    return ways

def nearest_lane(ways, tx, ty):
    """nearest point on any way segment to (tx,ty); return (px,py,yaw,dist)."""
    best = None
    for seq in ways:
        for (x0,y0),(x1,y1) in zip(seq, seq[1:]):
            dx,dy = x1-x0, y1-y0; L2 = dx*dx+dy*dy
            if L2 < 1e-6: continue
            t = max(0.0, min(1.0, ((tx-x0)*dx+(ty-y0)*dy)/L2))
            px,py = x0+t*dx, y0+t*dy
            d = math.hypot(px-tx, py-ty)
            if best is None or d < best[3]:
                best = (px, py, math.atan2(dy,dx), d)
    return best

def yaw_to_quat(yaw):
    return math.sin(yaw/2), math.cos(yaw/2)

def main():
    tx, ty = float(sys.argv[1]), float(sys.argv[2])
    ways = load_ways()
    px, py, yaw, dist = nearest_lane(ways, tx, ty)
    qz, qw = yaw_to_quat(yaw)
    print(f"target=({tx:.1f},{ty:.1f}) -> lane pt=({px:.1f},{py:.1f}) yaw={math.degrees(yaw):.0f}deg dist={dist:.1f}m")

    rclpy.init(); n = Node('drive_to')
    def call(cli, req, name):
        if not cli.wait_for_service(timeout_sec=8.0): print(f"{name}: no service"); return None
        fut = cli.call_async(req); rclpy.spin_until_future_complete(n, fut, timeout_sec=15.0)
        return fut.result()

    clr = n.create_client(ClearRoute, '/api/routing/clear_route')
    call(clr, ClearRoute.Request(), 'clear'); time.sleep(1.5)

    srp = n.create_client(SetRoutePoints, '/api/routing/set_route_points')
    req = SetRoutePoints.Request(); req.header.frame_id = 'map'
    req.goal.position.x = px; req.goal.position.y = py; req.goal.position.z = 43.1
    req.goal.orientation.z = qz; req.goal.orientation.w = qw
    res = call(srp, req, 'set_route')
    ok = res and res.status.success
    print('route:', 'SET' if ok else f'FAILED ({res.status.message if res else "timeout"})')
    if not ok: return
    time.sleep(3.0)
    eng = n.create_client(ChangeOperationMode, '/api/operation_mode/change_to_autonomous')
    res = call(eng, ChangeOperationMode.Request(), 'engage')
    print('engage:', 'OK -> DRIVING' if (res and res.status.success) else f'failed ({res.status.message if res else "timeout"})')

if __name__ == '__main__':
    main()
