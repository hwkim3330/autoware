#!/usr/bin/env python3
"""Continuous autonomous driving on a real-map lanelet2 (planning_simulator).

Runs in the autoware container. Loads the lanelet2 map, builds the routing graph,
finds a well-connected start lanelet, then loops:
  STOP + clear route -> seed the start (re-seed each trip = always a good start) ->
  settle -> set a far reachable goal -> wait for availability -> engage ->
  drive until arrival/stuck -> repeat (new goal).

Poses are taken in Autoware's LOCAL frame (lanelet point local_x/local_y attrs)
so they match map_loader's projector_type:local. The per-trip clear+reseed+settle
is what makes it reliable (a stale route or un-settled seed gives empty routes).

Usage (in container): python3 auto_realmap_drive.py <site>
"""
import math, subprocess, sys, time
import lanelet2
from lanelet2.projection import UtmProjector
from lanelet2.io import Origin, load

SITE = sys.argv[1] if len(sys.argv) > 1 else "pangyo"
MAP = f"/root/autoware_map/{SITE}/lanelet2_map.osm"
ORIGIN_F = f"/root/autoware_map/{SITE}/{SITE}.origin"


def ros(a, t=30):
    return subprocess.run(
        ["bash", "-lc", "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; "
         "source /opt/autoware/setup.bash; " + a], capture_output=True, text=True, timeout=t)


def q(yaw):
    return math.sin(math.radians(yaw) / 2), math.cos(math.radians(yaw) / 2)


def loc(p):
    try:
        return float(p.attributes["local_x"]), float(p.attributes["local_y"])
    except Exception:
        return None


def cline(ll):
    L = [loc(p) for p in ll.leftBound if loc(p)]
    R = [loc(p) for p in ll.rightBound if loc(p)]
    n = min(len(L), len(R))
    return [((L[i][0] + R[i][0]) / 2, (L[i][1] + R[i][1]) / 2) for i in range(n)]


def sub(ll):
    try:
        return ll.attributes["subtype"]
    except Exception:
        return ""


def pose(x, y, yaw):
    z, w = q(yaw)
    return (f"'{{header: {{frame_id: map}}, pose: {{pose: {{position: {{x: {x}, y: {y}, z: 0.0}}, "
            f"orientation: {{z: {z}, w: {w}}}}}, covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, "
            f"0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.068]}}}}'")


def seed(x, y, yaw):
    ros(f"ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped {pose(x,y,yaw)}", 20)


def main():
    la, lo = [float(v) for v in open(ORIGIN_F).read().split()]
    m = load(MAP, UtmProjector(Origin(la, lo)))
    rules = lanelet2.traffic_rules.create(lanelet2.traffic_rules.Locations.Germany,
                                          lanelet2.traffic_rules.Participants.Vehicle)
    g = lanelet2.routing.RoutingGraph(m, rules)
    road = [ll for ll in m.laneletLayer if sub(ll) == "road"]
    conn = sorted(((ll, len(g.reachableSet(ll, 800.0, 0))) for ll in road[::2]),
                  key=lambda c: -c[1])
    conn = [c for c in conn if c[1] > 60]
    if not conn:
        print("no well-connected lanelet", flush=True); return
    print(f"{len(conn)} well-connected starts (best reaches {conn[0][1]})", flush=True)

    trip = 0
    while True:
        trip += 1
        start = conn[trip % min(8, len(conn))][0]      # rotate among the best starts
        sc = cline(start)
        if len(sc) < 4:
            continue
        sx, sy = sc[0]; sx2, sy2 = sc[3]
        syaw = math.degrees(math.atan2(sy2 - sy, sx2 - sx))
        # far reachable goal from this start
        goal = None
        for ll in g.reachableSet(start, 800.0, 0):
            cc = cline(ll)
            if len(cc) < 2:
                continue
            gx, gy = cc[len(cc) // 2]
            d = math.hypot(gx - sx, gy - sy)
            if 150 < d < 500 and g.getRoute(start, ll) and len(g.getRoute(start, ll).shortestPath()) >= 5:
                gx2, gy2 = cc[min(len(cc) // 2 + 1, len(cc) - 1)]
                goal = (gx, gy, math.degrees(math.atan2(gy2 - gy, gx2 - gx))); break
        if goal is None:
            continue
        gx, gy, gyaw = goal
        # clean slate then drive
        ros("ros2 service call /api/operation_mode/change_to_stop autoware_adapi_v1_msgs/srv/ChangeOperationMode '{}'", 20)
        ros("ros2 service call /api/routing/clear_route autoware_adapi_v1_msgs/srv/ClearRoute '{}'", 20)
        time.sleep(2)
        seed(sx, sy, syaw)
        time.sleep(10)
        z, w = q(gyaw)
        r = ros(f"ros2 service call /api/routing/set_route_points autoware_adapi_v1_msgs/srv/SetRoutePoints "
                f"'{{header: {{frame_id: map}}, goal: {{position: {{x: {gx}, y: {gy}, z: 0.0}}, "
                f"orientation: {{z: {z}, w: {w}}}}}}}'", 40)
        ok = "success=True" in r.stdout
        print(f"trip {trip}: ({sx:.0f},{sy:.0f})->({gx:.0f},{gy:.0f}) route={'OK' if ok else 'EMPTY'}", flush=True)
        if not ok:
            continue
        for _ in range(18):
            av = ros("ros2 topic echo --once --field is_autonomous_mode_available /api/operation_mode/state", 6)
            if "true" in av.stdout.lower():
                ros("ros2 service call /api/operation_mode/change_to_autonomous autoware_adapi_v1_msgs/srv/ChangeOperationMode '{}'", 15)
                break
            time.sleep(2)
        # drive until arrival or stuck
        last = (sx, sy); stuck = 0
        for _ in range(50):
            time.sleep(3)
            rs = ros("ros2 topic echo --once --field state /api/routing/state", 6)
            if rs.stdout.strip().startswith("3"):
                print(f"trip {trip}: arrived", flush=True); break
            s = ros("ros2 topic echo --once --field twist.twist.linear.x /localization/kinematic_state", 6)
            try:
                v = float(s.stdout.strip().splitlines()[0])
            except Exception:
                v = 0.0
            if abs(v) < 0.2:
                stuck += 1
                if stuck >= 7:
                    print(f"trip {trip}: stuck, next", flush=True); break
            else:
                stuck = 0


if __name__ == "__main__":
    main()
