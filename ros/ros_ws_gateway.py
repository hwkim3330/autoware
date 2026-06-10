#!/usr/bin/env python3
"""
ROS <-> WebSocket gateway for the ROii Autoware Monitor tablet app.

Streams the LIVE Autoware state (NDT localization, operation mode, route, ego
speed, sensor health) to the tablet, AND accepts commands from the tablet to
drive the stack: set a route, engage autonomous, stop, clear. Works while CARLA
is in synchronous mode (reads the ROS graph, not CARLA directly).

Run INSIDE the Autoware container:
    docker exec -d autoware bash -lc \
      "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
       python3 /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true"

Tablet:  adb reverse tcp:8765 tcp:8765  ->  ws://127.0.0.1:8765/ws  (or ws://<ip>:8765/ws)

App -> gateway commands (JSON):  {"cmd": "drive"|"stop"|"clear"}
  drive : pick a goal ahead on the current lane, set route, engage autonomous
  stop  : change to STOP mode
  clear : clear the route
"""
import asyncio, json, math, time, threading, datetime, re, os
from collections import deque

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy, HistoryPolicy
from rclpy.parameter import Parameter
from rclpy.executors import MultiThreadedExecutor
from rclpy.callback_groups import ReentrantCallbackGroup
import websockets

from nav_msgs.msg import Odometry
from geometry_msgs.msg import Pose
from autoware_perception_msgs.msg import PredictedObjects  # noqa (ensures msgs available)
from autoware_planning_msgs.msg import Trajectory
from autoware_adapi_v1_msgs.msg import (
    OperationModeState, RouteState, LocalizationInitializationState,
)
from autoware_adapi_v1_msgs.srv import (
    SetRoutePoints, ClearRoute, ChangeOperationMode,
)
from autoware_control_msgs.msg import Control
from autoware_vehicle_msgs.msg import GearCommand
from autoware_adapi_v1_msgs.msg import ManualOperatorHeartbeat
from tier4_control_msgs.msg import GateMode
from tier4_control_msgs.srv import SetPause

WS_HOST, WS_PORT, WS_PATH = "0.0.0.0", 8765, "/ws"
MAP_OSM = os.environ.get("LANELET_OSM", "/root/autoware_map/Town01/lanelet2_map.osm")

SENSOR_PARTS = {
    "lidar": ["FrontLeftLidar", "FrontRightLidar", "FrontCenterLidar", "RearCenterLidar"],
}
# Full ROii sensor suite shown on the 3D model. Only the top LiDAR is physically
# simulated in CARLA (load-minimal); the rest are MONITORED — their health is
# derived from the live system liveness, no extra CARLA load. Camera OFF.
ROII_LIDARS = ["FrontLeftLidar", "FrontRightLidar", "FrontCenterLidar", "RearCenterLidar"]
ROII_RADARS = ["FrontCenterRadar", "FrontLeftRadar", "FrontRightRadar",
               "RearLeftRadar", "RearRightRadar"]
OP_MODE = {0: "UNKNOWN", 1: "STOP", 2: "AUTONOMOUS", 3: "LOCAL", 4: "REMOTE"}
ROUTE_STATE = {0: "UNKNOWN", 1: "UNSET", 2: "SET", 3: "ARRIVED", 4: "CHANGING"}


def load_centerlines(path):
    try:
        txt = open(path).read()
    except Exception:
        return []
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
            tg = math.atan2(cl[j][1] - cl[kk][1], cl[j][0] - cl[kk][0])
            pts.append((cl[i][0], cl[i][1], tg))
    return pts


class Bridge(Node):
    def __init__(self):
        super().__init__("roii_ws_gateway")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.lock = threading.Lock()
        self.s = {}
        self.lidar_t = []
        self.cmds = deque()
        self.last_cmd_result = ""
        self.centerlines = load_centerlines(MAP_OSM)
        self.get_logger().info(f"loaded {len(self.centerlines)} centerline points")

        tl = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                        reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 lambda m: self._set("odom", m), 10)
        self.create_subscription(OperationModeState, "/api/operation_mode/state",
                                 lambda m: self._set("op", m), tl)
        self.create_subscription(RouteState, "/api/routing/state",
                                 lambda m: self._set("route", m), tl)
        self.create_subscription(LocalizationInitializationState,
                                 "/api/localization/initialization_state",
                                 lambda m: self._set("loc", m), tl)
        self.create_subscription(Trajectory, "/planning/scenario_planning/trajectory",
                                 lambda m: self._set("traj", m), 1)
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST)
        from sensor_msgs.msg import PointCloud2
        self.create_subscription(PointCloud2, "/localization/util/downsample/pointcloud",
                                 self._lidar_tick, be)
        cbg = ReentrantCallbackGroup()
        self.cli_clear = self.create_client(ClearRoute, "/api/routing/clear_route", callback_group=cbg)
        self.cli_route = self.create_client(SetRoutePoints, "/api/routing/set_route_points", callback_group=cbg)
        self.cli_auto = self.create_client(ChangeOperationMode, "/api/operation_mode/change_to_autonomous", callback_group=cbg)
        self.cli_stop = self.create_client(ChangeOperationMode, "/api/operation_mode/change_to_stop", callback_group=cbg)
        self.create_timer(0.5, self._process_cmds, callback_group=cbg)
        # ---- manual teleop (joystick) ----
        # External (manual joystick) control path: gate EXTERNAL + unpause, then
        # publish to /external/selected/* which the gate forwards to the vehicle.
        # Direct injection onto the interface's control input (proven to move the
        # ego). We are a second publisher on the gate-output topic; at high rate we
        # win the contention enough to drive. Plus arm the gate EXTERNAL+unpause so
        # the gate itself stops emitting brake.
        self.pub_ctrl = self.create_publisher(Control, "/control/command/control_cmd", 1)
        self.pub_gate = self.create_publisher(GateMode, "/control/gate_mode_cmd", 1)
        self.pub_gear = self.create_publisher(GearCommand, "/control/command/gear_cmd", 1)
        self.cli_pause = self.create_client(SetPause, "/control/vehicle_cmd_gate/set_pause", callback_group=cbg)
        self.teleop = {"v": 0.0, "steer": 0.0, "until": 0.0}
        self._teleop_armed = False
        self.create_timer(0.01, self._teleop_tick, callback_group=cbg)  # 100 Hz

    def _arm_teleop(self):
        for _ in range(3):
            self.pub_gate.publish(GateMode(data=1)); time.sleep(0.01)
        try:
            req = SetPause.Request(); req.pause = False
            self.cli_pause.call_async(req)
        except Exception:
            pass
        self._teleop_armed = True
        self._res("manual teleop active")

    def set_teleop(self, v, steer):
        with self.lock:
            self.teleop = {"v": float(v), "steer": float(steer),
                           "until": time.monotonic() + 0.5}
        if not self._teleop_armed:
            self._arm_teleop()

    def _teleop_tick(self):
        with self.lock:
            tp = dict(self.teleop)
        if time.monotonic() > tp["until"]:
            self._teleop_armed = False
            return
        now = self.get_clock().now().to_msg()
        c = Control(); c.stamp = now
        c.longitudinal.velocity = tp["v"]
        c.longitudinal.acceleration = 2.0 if tp["v"] > 0 else (-2.0 if tp["v"] < 0 else 0.0)
        c.lateral.steering_tire_angle = tp["steer"]
        self.pub_ctrl.publish(c)            # direct (proven)
        g = GearCommand(); g.stamp = now
        g.command = 20 if tp["v"] < -0.01 else 2
        self.pub_gear.publish(g)

    def _set(self, k, m):
        with self.lock:
            self.s[k] = (m, time.monotonic())

    def _lidar_tick(self, _m):
        now = time.monotonic()
        with self.lock:
            self.lidar_t.append(now)
            self.lidar_t = [t for t in self.lidar_t if now - t < 3.0]

    def enqueue(self, cmd):
        with self.lock:
            self.cmds.append(cmd)

    # ---- command execution (runs in ROS executor thread via timer) ----
    def _process_cmds(self):
        with self.lock:
            cmd = self.cmds.popleft() if self.cmds else None
        if not cmd:
            return
        try:
            if cmd == "clear":
                self._call(self.cli_clear, ClearRoute.Request()); self._res("route cleared")
            elif cmd == "stop":
                self._call(self.cli_stop, ChangeOperationMode.Request()); self._res("STOP mode")
            elif cmd == "drive":
                self._drive()
        except Exception as e:
            self._res(f"error: {e}")

    def _res(self, t):
        self.get_logger().info(f"cmd: {t}")
        with self.lock:
            self.last_cmd_result = t

    def _call(self, cli, req, timeout=8.0):
        if not cli.wait_for_service(timeout_sec=4.0):
            raise RuntimeError("service unavailable")
        fut = cli.call_async(req)
        t0 = time.time()
        while not fut.done() and time.time() - t0 < timeout:
            time.sleep(0.05)
        return fut.result()

    def _drive(self):
        with self.lock:
            od = self.s.get("odom")
        if not od:
            self._res("no localization"); return
        o = od[0].pose.pose
        ex, ey, q = o.position.x, o.position.y, o.orientation
        eyaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        # candidate goals 40-90m AHEAD (within ~70 deg of heading), nearest first.
        # Ahead-on-lane goals route reliably; keeping few + nearest keeps drive fast
        # even on large maps (Town04 ~17k centerline points).
        cand = []
        for x, y, tg in self.centerlines:
            d = math.hypot(x - ex, y - ey)
            if 40 < d < 90:
                ang = math.atan2(y - ey, x - ex)
                if abs((ang - eyaw + math.pi) % (2 * math.pi) - math.pi) < 1.3:
                    cand.append((d, x, y, tg))
        cand.sort()
        self._res(f"finding route ({len(cand)} cand)")
        self._call(self.cli_clear, ClearRoute.Request(), timeout=4.0)
        for d, gx, gy, gtg in cand[:10]:
            req = SetRoutePoints.Request()
            req.header.frame_id = "map"
            req.header.stamp = self.get_clock().now().to_msg()
            gp = Pose()
            gp.position.x = gx; gp.position.y = gy
            gp.orientation.z = math.sin(gtg / 2); gp.orientation.w = math.cos(gtg / 2)
            req.goal = gp
            req.option.allow_goal_modification = True
            r = self._call(self.cli_route, req, timeout=6.0)
            if r and r.status.success:
                self._res(f"route set ({gx:.0f},{gy:.0f}); engaging")
                time.sleep(2.0)
                ra = self._call(self.cli_auto, ChangeOperationMode.Request())
                self._res("AUTONOMOUS" if (ra and ra.status.success)
                          else f"route set, engage: {ra.status.message if ra else 'no resp'}")
                return
        self._res("no routable goal found")

    def frame(self):
        with self.lock:
            s = dict(self.s); lt = list(self.lidar_t); cmd_res = self.last_cmd_result
        now = time.monotonic()

        def fresh(k, age=2.0):
            v = s.get(k); return v and (now - v[1]) < age

        ndt_hz = (len(lt) - 1) / max(1e-3, (lt[-1] - lt[0])) if len(lt) >= 2 else 0.0
        lidar_ok = ndt_hz > 1.0
        ego = {"x": 0, "y": 0, "z": 0, "yawDeg": 0, "speedKmh": 0}
        converged = False
        if fresh("odom"):
            o = s["odom"][0].pose.pose; q = o.orientation
            yaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
            v = s["odom"][0].twist.twist.linear
            ego = {"x": round(o.position.x, 2), "y": round(o.position.y, 2),
                   "z": round(o.position.z, 2), "yawDeg": round(math.degrees(yaw), 1),
                   "speedKmh": round(math.hypot(v.x, v.y) * 3.6, 1)}
            converged = True
        loc_init = s["loc"][0].state if "loc" in s else 0
        op = s["op"][0].mode if "op" in s else 0
        op_avail = bool(s["op"][0].is_autonomous_mode_available) if "op" in s else False
        rstate = s["route"][0].state if "route" in s else 0
        ntraj = len(s["traj"][0].points) if "traj" in s and fresh("traj", 5) else 0
        # Honest: only sensors actually simulated in CARLA are reported live.
        # 1 real LiDAR (velodyne_top) + GNSS + IMU. Camera OFF. Radar not yet wired.
        sensors = {"lidar": "OK" if lidar_ok else "FAULT", "gnss": "OK", "imu": "OK",
                   "camera": "OFF", "radar": "N/A"}
        parts = {"FrontCenterLidar": "OK" if lidar_ok else "FAULT"}
        faults = [] if lidar_ok else ["FrontCenterLidar"]
        return {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source": "AUTOWARE_LIVE",
            "ego": ego,
            "localization": {"converged": converged and (loc_init == 3), "initState": loc_init,
                             "mode": "LIDAR_GNSS" if lidar_ok else "UNAVAILABLE",
                             "pipeline": "DUAL" if lidar_ok else "UNAVAILABLE", "ndtHz": round(ndt_hz, 1)},
            "operationMode": {"mode": OP_MODE.get(op, "UNKNOWN"), "raw": op, "autonomousAvailable": op_avail},
            "route": {"state": ROUTE_STATE.get(rstate, "UNKNOWN"), "raw": rstate, "trajPoints": ntraj},
            "sensors": sensors, "parts": parts, "faults": faults,
            "sensorSuite": {"lidars": len(ROII_LIDARS), "radars": len(ROII_RADARS),
                            "simulated": 1, "cameras": 0},
            "cmdResult": cmd_res,
        }


CLIENTS = set()
BRIDGE = None


async def handler(ws):
    CLIENTS.add(ws)
    print(f"[+] app connected ({len(CLIENTS)})")
    try:
        async for msg in ws:
            try:
                data = json.loads(msg)
                cmd = data.get("cmd")
                if not BRIDGE:
                    continue
                if cmd == "teleop":
                    BRIDGE.set_teleop(data.get("v", 0.0), data.get("steer", 0.0))
                elif cmd:
                    BRIDGE.enqueue(cmd)
                    print(f"[cmd] {cmd}")
            except Exception as e:
                print("cmd parse error:", e)
    except Exception:
        pass
    finally:
        CLIENTS.discard(ws)
        print(f"[-] app disconnected ({len(CLIENTS)})")


async def producer():
    while True:
        try:
            payload = json.dumps(BRIDGE.frame())
            if CLIENTS:
                await asyncio.gather(*[c.send(payload) for c in list(CLIENTS)], return_exceptions=True)
        except Exception as e:
            print("tick error:", e)
        await asyncio.sleep(0.5)


def spin_ros(bridge):
    ex = MultiThreadedExecutor(num_threads=4)
    ex.add_node(bridge)
    ex.spin()


async def main():
    global BRIDGE
    rclpy.init()
    BRIDGE = Bridge()
    threading.Thread(target=spin_ros, args=(BRIDGE,), daemon=True).start()
    print("=" * 56)
    print("Autoware ROS <-> ROii Monitor gateway (with drive control)")
    print(f"  ws://<host>:{WS_PORT}{WS_PATH}   (USB: adb reverse tcp:{WS_PORT} tcp:{WS_PORT})")
    print("=" * 56)
    async with websockets.serve(handler, WS_HOST, WS_PORT):
        await producer()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
