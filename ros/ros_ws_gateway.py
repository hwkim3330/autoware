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
# CARLA spawn "x, y, z, roll, pitch, yaw" (CARLA coords) -- for the respawn cmd
CARLA_SPAWN = os.environ.get("CARLA_SPAWN", "")
RVIZ_DISPLAY = os.environ.get("RVIZ_DISPLAY", ":1")
MESH_DIR = "/opt/autoware/share/sample_vehicle_description/mesh"

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
        txt = open(path).read().replace("'", '"')  # JOSM single quotes
    except Exception:
        return [], []
    nd = {}
    for m in re.finditer(r'<node id="(-?\d+)"[^>]*>(.*?)</node>', txt, re.S):
        b = m.group(2)
        x = re.search(r'k="local_x" v="([-\d.]+)"', b)
        y = re.search(r'k="local_y" v="([-\d.]+)"', b)
        if x and y:
            nd[m.group(1)] = (float(x.group(1)), float(y.group(1)))
    if not nd:
        # MGRS map (no local_x/local_y, e.g. real-world maps): map frame =
        # UTM easting/northing mod 100 km (MGRS square).
        try:
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
        except Exception:
            pass
    wy = {}
    for m in re.finditer(r'<way id="(-?\d+)"[^>]*>(.*?)</way>', txt, re.S):
        refs = [r for r in re.findall(r'<nd ref="(-?\d+)"', m.group(2)) if r in nd]
        if refs:
            wy[m.group(1)] = [nd[r] for r in refs]
    pts, polys = [], []
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
        # orient by geometry: keep the LEFT boundary on the left of travel
        # (some osm store boundary points reversed -> wrong headings/goals).
        if len(cl) >= 2:
            dx, dy = cl[1][0] - cl[0][0], cl[1][1] - cl[0][1]
            lx, ly = l[0][0] - cl[0][0], l[0][1] - cl[0][1]
            if dx * ly - dy * lx < 0:
                cl.reverse()
        for i in range(len(cl)):
            j = min(i + 1, len(cl) - 1)
            kk = max(i - 1, 0)
            tg = math.atan2(cl[j][1] - cl[kk][1], cl[j][0] - cl[kk][0])
            pts.append((cl[i][0], cl[i][1], tg))
        # per-lanelet polyline (downsampled) so the tablet can stroke ROADS
        # instead of dots — Tesla-style continuous road rendering.
        step = max(1, len(cl) // 20)
        poly = cl[::step]
        if poly[-1] != cl[-1]:
            poly.append(cl[-1])
        polys.append([[round(p[0], 1), round(p[1], 1)] for p in poly])
    return pts, polys


class Bridge(Node):
    def __init__(self):
        super().__init__("roii_ws_gateway")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.lock = threading.Lock()
        self.s = {}
        self.lidar_t = []
        self.cmds = deque()
        self.last_cmd_result = ""
        self.centerlines, self.lane_polys = load_centerlines(MAP_OSM)
        self.get_logger().info(
            f"loaded {len(self.centerlines)} centerline points, {len(self.lane_polys)} lane polylines")

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
        from std_msgs.msg import String as _Str
        self.create_subscription(_Str, "/multimode/mode",
                                 lambda m: self._set("mmode", m), 1)
        self.pub_inject = self.create_publisher(_Str, "/multimode/inject", 1)
        # vehicle status / safety for the full-Autoware dashboard
        from autoware_vehicle_msgs.msg import SteeringReport, TurnIndicatorsReport
        self.create_subscription(SteeringReport, "/vehicle/status/steering_status",
                                 lambda m: self._set("steer", m), 10)
        self.create_subscription(TurnIndicatorsReport, "/vehicle/status/turn_indicators_status",
                                 lambda m: self._set("blink", m), 1)
        try:
            from autoware_adapi_v1_msgs.msg import MrmState
            self.create_subscription(MrmState, "/api/fail_safe/mrm_state",
                                     lambda m: self._set("mrm", m), 1)
        except Exception:
            pass
        from autoware_vehicle_msgs.msg import TurnIndicatorsCommand
        self.create_subscription(TurnIndicatorsCommand, "/control/command/turn_indicators_cmd",
                                 lambda m: self._set("blinkcmd", m), 1)
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST)
        from sensor_msgs.msg import PointCloud2
        self.create_subscription(PointCloud2, "/localization/util/downsample/pointcloud",
                                 self._lidar_tick, be)
        # per-LiDAR liveness (ROii 4-lidar suite; in 1-lidar mode only front maps)
        self.lidar_part_t = {k: [] for k in
                             ("front", "rear", "side_left", "side_right")}
        for key in self.lidar_part_t:
            self.create_subscription(
                PointCloud2, f"/sensing/lidar/{key}/pointcloud_before_sync",
                (lambda k: lambda m: self._part_tick(k))(key), be)
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
        # single thread owns ALL carla client calls (libcarla is not thread-safe)
        self._carla_lock = threading.Lock()
        threading.Thread(target=self._carla_loop, daemon=True).start()

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

    def _carla_ego(self):
        """Lazy CARLA client + ego handle for direct manual control."""
        try:
            import carla
            if not hasattr(self, "_carla_cl"):
                self._carla_cl = carla.Client("localhost", 2000)
                self._carla_cl.set_timeout(5.0)
                self._carla_mod = carla
            ego = getattr(self, "_carla_ego_a", None)
            if ego is None or not ego.is_alive:
                ego = next((a for a in self._carla_cl.get_world().get_actors().filter("vehicle.*")
                            if a.attributes.get("role_name") == "ego_vehicle"), None)
                self._carla_ego_a = ego
            return ego
        except Exception:
            return None

    def _carla_loop(self):
        """Manual mode drives the CARLA actor directly: the Autoware chain turns
        a negative-velocity command into BRAKE (reverse never reaches CARLA) and
        the gate fights direct injection. ~30 Hz outruns the interface's own
        apply_control, so manual forward/reverse is crisp."""
        while True:
            time.sleep(0.033)
            with self.lock:
                tp = dict(self.teleop)
            if time.monotonic() > tp["until"]:
                continue
            try:
                with self._carla_lock:
                    ego = self._carla_ego()
                    if ego is None:
                        continue
                    carla = self._carla_mod
                    mag = min(abs(tp["v"]) / 6.0, 1.0) * 0.7
                    ego.apply_control(carla.VehicleControl(
                        throttle=mag if abs(tp["v"]) > 0.05 else 0.0,
                        steer=max(-1.0, min(1.0, -tp["steer"] * 2.0)),
                        brake=0.0 if abs(tp["v"]) > 0.05 else 0.4,
                        reverse=tp["v"] < -0.05))
            except Exception:
                self._carla_ego_a = None

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
        # Direct CARLA control happens in a DEDICATED thread (_carla_loop):
        # libcarla is not thread-safe; calling it from the 100 Hz reentrant
        # executor timer caused silent SIGSEGV crashes of the gateway.

    def _set(self, k, m):
        with self.lock:
            self.s[k] = (m, time.monotonic())

    def _part_tick(self, key):
        now = time.monotonic()
        with self.lock:
            ts = self.lidar_part_t[key]
            ts.append(now)
            self.lidar_part_t[key] = [t for t in ts if now - t < 3.0]

    def _lidar_tick(self, _m):
        now = time.monotonic()
        with self.lock:
            self.lidar_t.append(now)
            self.lidar_t = [t for t in self.lidar_t if now - t < 3.0]

    def enqueue(self, cmd):
        # Latest intent wins: a new command REPLACES anything still queued
        # (taps piling up made the gateway feel unresponsive for minutes).
        with self.lock:
            self.cmds.clear()
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
            elif isinstance(cmd, tuple) and cmd[0] == "goto":
                self._goto(cmd[1], cmd[2])
            elif cmd == "respawn":
                self._respawn()
            elif cmd == "fail_lidar":
                from std_msgs.msg import String as _Str
                self.pub_inject.publish(_Str(data="lidar_fail"))
                self._res("FAULT INJECTED: lidar -> multimode fallback")
            elif cmd == "heal":
                from std_msgs.msg import String as _Str
                self.pub_inject.publish(_Str(data="clear"))
                self._res("fault cleared -> auto mode selection")
            elif isinstance(cmd, tuple) and cmd[0] == "vehicle":
                self._vehicle(cmd[1])
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
        if not cand:
            # some lanelets store centerline points reversed vs travel direction
            # -> "ahead" filter yields nothing. Fall back to any-direction goals;
            # allow_goal_modification + the mission planner sort out routability.
            cand = sorted((math.hypot(x - ex, y - ey), x, y, tg)
                          for x, y, tg in self.centerlines
                          if 40 < math.hypot(x - ex, y - ey) < 90)
        # prefer a few farther goals first (a meaningful drive), then nearer ones
        order = cand[len(cand) // 3: len(cand) // 3 + 4] + cand[:4]
        self._res(f"finding route ({len(cand)} cand)")
        self._call(self.cli_clear, ClearRoute.Request(), timeout=4.0)
        for d, gx, gy, gtg in order[:5]:
            # try the stored tangent AND its 180-deg flip: converted maps may
            # store boundary roles swapped, so the tangent can be anti-parallel
            # to the lane -- the planner rejects those instantly (cheap retry).
            for g2 in (gtg, gtg + math.pi):
                r = self._set_route_to(gx, gy, g2)
                if (r and r.status.success) or self._route_is_set():
                    self._engage(gx, gy); return
        # set_route_points can answer late; give the planner a moment, then check.
        time.sleep(2.0)
        if self._route_is_set():
            self._engage(None, None); return
        self._res("no routable goal found")

    def _route_is_set(self):
        with self.lock:
            r = self.s.get("route")
        return bool(r and r[0].state == 2)  # RouteState.SET

    def _engage(self, gx, gy):
        tag = f" ({gx:.0f},{gy:.0f})" if gx is not None else ""
        self._res(f"route set{tag}; engaging")
        # The trajectory appears ~2-3 s after the route and autonomous mode only
        # becomes AVAILABLE then -- retry the engage until it sticks (~20 s).
        for i in range(6):
            time.sleep(2.0)
            ra = self._call(self.cli_auto, ChangeOperationMode.Request())
            if ra and ra.status.success:
                self._res("AUTONOMOUS"); return
            self._res(f"engaging... ({i + 1}/6)")
        self._res(f"route set, engage failed: {ra.status.message if ra else 'no resp'}")

    def _set_route_to(self, gx, gy, gtg, timeout=14.0):
        """Set a route to one goal pose; return the service result."""
        req = SetRoutePoints.Request()
        req.header.frame_id = "map"
        req.header.stamp = self.get_clock().now().to_msg()
        gp = Pose()
        gp.position.x = float(gx); gp.position.y = float(gy)
        gp.orientation.z = math.sin(gtg / 2); gp.orientation.w = math.cos(gtg / 2)
        req.goal = gp
        req.option.allow_goal_modification = True
        return self._call(self.cli_route, req, timeout=timeout)

    def _goto(self, tx, ty):
        """Tesla-style tap-to-go: snap the tapped (x,y) to the nearest lane
        centerline points and route there, then engage autonomous."""
        if tx is None or ty is None or not self.centerlines:
            self._res("goto: bad point"); return
        tx, ty = float(tx), float(ty)
        # spatially-DIVERSE candidates around the tap: the nearest N polyline
        # points are usually the same spot on one lanelet -- if that lanelet is
        # goal-ineligible (intersection interior etc.) all attempts fail. Pick
        # the nearest, then the next ones at least 6 m apart, up to 4 spots.
        ranked = sorted(self.centerlines, key=lambda p: math.hypot(p[0] - tx, p[1] - ty))
        gx, gy, gtg = ranked[0]
        self._res(f"goto ({tx:.0f},{ty:.0f}) -> snapped {math.hypot(gx-tx, gy-ty):.0f}m")
        self._call(self.cli_clear, ClearRoute.Request(), timeout=4.0)
        # 1) exact snap, ONE short attempt each orientation (goal-ineligible
        #    lanelets -- intersection interiors -- make the planner hang)
        for g2 in (gtg, gtg + math.pi):
            r = self._set_route_to(gx, gy, g2, timeout=8.0)
            if (r and r.status.success) or self._route_is_set():
                self._engage(gx, gy); return
        # 2) fallback: drive TOWARD the tap -- proven drive-style goals 40-90 m
        #    from the ego in the tap's bearing; user taps again as they close in.
        with self.lock:
            od = self.s.get("odom")
        if od:
            o = od[0].pose.pose
            ex, ey = o.position.x, o.position.y
            brg = math.atan2(ty - ey, tx - ex)
            cand = sorted(
                (math.hypot(x - ex, y - ey), x, y, tg)
                for x, y, tg in self.centerlines
                if 40 < math.hypot(x - ex, y - ey) < 90
                and abs((math.atan2(y - ey, x - ex) - brg + math.pi) % (2 * math.pi) - math.pi) < 1.0)
            self._res(f"goto: heading toward tap ({len(cand)} cand)")
            for d, cx2, cy2, ct in cand[len(cand) // 3: len(cand) // 3 + 3] + cand[:3]:
                for g2 in (ct, ct + math.pi):
                    r = self._set_route_to(cx2, cy2, g2, timeout=8.0)
                    if (r and r.status.success) or self._route_is_set():
                        self._engage(cx2, cy2); return
        time.sleep(2.0)
        if self._route_is_set():
            self._engage(None, None); return
        self._res("goto: no routable goal near tap")

    def _respawn(self):
        """Teleport the CARLA ego back to the spawn point and re-seed the
        localization -- recovers from wall crashes without a full relaunch."""
        if not CARLA_SPAWN:
            self._res("respawn: no CARLA_SPAWN configured"); return
        # 1) STOP + route clear FIRST -- otherwise autonomous keeps driving the
        #    teleported car away while we re-seed localization.
        try:
            self._call(self.cli_stop, ChangeOperationMode.Request(), timeout=6.0)
        except Exception:
            pass
        self._call(self.cli_clear, ClearRoute.Request(), timeout=4.0)
        time.sleep(1.0)
        try:
            x, y, z, roll, pitch, yaw = [float(v) for v in CARLA_SPAWN.split(",")]
            with self._carla_lock:
                ego = self._carla_ego()
                if ego is None:
                    self._res("respawn: ego not found"); return
                carla = self._carla_mod
                tf = carla.Transform(carla.Location(x=x, y=y, z=z + 0.3),
                                     carla.Rotation(roll=roll, pitch=pitch, yaw=yaw))
                for _ in range(3):   # sync mode can swallow one set_transform
                    ego.set_target_velocity(carla.Vector3D(0, 0, 0))
                    ego.set_angular_velocity(carla.Vector3D(0, 0, 0))
                    ego.set_transform(tf)
                    time.sleep(0.3)
            self._res("teleported; re-seeding localization")
        except Exception as e:
            self._res(f"respawn error: {e}"); return
        time.sleep(2.0)   # let the lidar see the new surroundings
        # 2) initialpose 재시딩 (CARLA -> Autoware: y/yaw 부호 반전), 3회 발행
        from geometry_msgs.msg import PoseWithCovarianceStamped
        if not hasattr(self, "pub_init"):
            self.pub_init = self.create_publisher(PoseWithCovarianceStamped, "/initialpose", 1)
            time.sleep(0.5)
        awyaw = math.radians(-yaw)
        for _ in range(3):
            m = PoseWithCovarianceStamped()
            m.header.frame_id = "map"
            m.header.stamp = self.get_clock().now().to_msg()
            m.pose.pose.position.x = x
            m.pose.pose.position.y = -y
            m.pose.pose.orientation.z = math.sin(awyaw / 2)
            m.pose.pose.orientation.w = math.cos(awyaw / 2)
            m.pose.covariance[0] = m.pose.covariance[7] = 0.25
            m.pose.covariance[35] = 0.068
            self.pub_init.publish(m)
            time.sleep(1.5)
        # 3) 수렴 확인
        for i in range(10):
            time.sleep(1.0)
            with self.lock:
                od = self.s.get("odom")
            if od:
                p = od[0].pose.pose.position
                if math.hypot(p.x - x, p.y - (-y)) < 5.0:
                    self._res("respawn OK -- at spawn, ready"); return
        self._res("respawn: teleported but localization not converged (try again)")

    def _vehicle(self, model):
        """Swap the rviz vehicle model (roii shuttle <-> KETI-badged lexus)
        and restart rviz. Runs as root inside the container."""
        import shutil, subprocess
        try:
            if model == "roii":
                shutil.copy(f"{MESH_DIR}/roii_vehicle.dae.src", f"{MESH_DIR}/lexus.dae")
            else:
                shutil.copy(f"{MESH_DIR}/lexus.dae.bak", f"{MESH_DIR}/lexus.dae")
            subprocess.run(["pkill", "-f", "rviz2"], check=False)
            time.sleep(1.5)
            env = dict(os.environ, DISPLAY=RVIZ_DISPLAY, XAUTHORITY="/root/.Xauthority")
            subprocess.Popen(
                ["bash", "-lc",
                 "source /opt/autoware/setup.bash; rviz2 -d /root/autoware_no_camera.rviz > /tmp/rviz.log 2>&1"],
                env=env, start_new_session=True)
            self._res(f"vehicle -> {model} (rviz restarting)")
        except Exception as e:
            self._res(f"vehicle error: {e}")

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
        steer_deg = (round(math.degrees(s["steer"][0].steering_tire_angle), 1)
                     if fresh("steer") else 0.0)
        blink = 0
        if fresh("blinkcmd", 3):
            blink = int(s["blinkcmd"][0].command)   # 1 disable, 2 left, 3 right
        elif fresh("blink", 3):
            blink = int(s["blink"][0].report)
        mrm = ""
        if "mrm" in s:
            mm = s["mrm"][0]
            if getattr(mm, "state", 0) not in (0, 1):   # not NORMAL
                mrm = {2: "MRM_OPERATING", 3: "MRM_SUCCEEDED", 4: "MRM_FAILED"}.get(mm.state, "MRM")
        planned_kmh = 0.0
        if "traj" in s and fresh("traj", 5) and s["traj"][0].points:
            planned_kmh = round(s["traj"][0].points[0].longitudinal_velocity_mps * 3.6, 1)
        # planned-path overlay for the tablet map (downsampled to ~120 pts)
        traj_path = []
        if "traj" in s and fresh("traj", 5):
            tp = s["traj"][0].points
            step = max(1, len(tp) // 120)
            traj_path = [[round(p.pose.position.x, 1), round(p.pose.position.y, 1)] for p in tp[::step]]
        # Honest: only sensors actually simulated in CARLA are reported live.
        # 1 real LiDAR (velodyne_top) + GNSS + IMU. Camera OFF. Radar not yet wired.
        sensors = {"lidar": "OK" if lidar_ok else "FAULT", "gnss": "OK", "imu": "OK",
                   "camera": "OFF", "radar": "N/A"}
        with self.lock:
            pt = {k: list(v) for k, v in self.lidar_part_t.items()}
        name_map = {"front": "FrontCenterLidar", "rear": "RearCenterLidar",
                    "side_left": "FrontLeftLidar", "side_right": "FrontRightLidar"}
        parts, faults = {}, []
        any_part = any(len(v) >= 2 for v in pt.values())
        for k, disp in name_map.items():
            ok = len(pt[k]) >= 2
            if any_part:
                parts[disp] = "OK" if ok else "FAULT"
                if not ok:
                    faults.append(disp)
        if not any_part:  # 1-lidar mode: report the single pipeline
            parts = {"FrontCenterLidar": "OK" if lidar_ok else "FAULT"}
            faults = [] if lidar_ok else ["FrontCenterLidar"]
        return {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source": "AUTOWARE_LIVE",
            "ego": ego,
            "localization": {"converged": converged and (loc_init == 3), "initState": loc_init,
                             "mode": (s["mmode"][0].data if "mmode" in s
                                      else ("LIDAR_GNSS" if lidar_ok else "UNAVAILABLE")),
                             "pipeline": "DUAL" if lidar_ok else "FALLBACK", "ndtHz": round(ndt_hz, 1)},
            "operationMode": {"mode": OP_MODE.get(op, "UNKNOWN"), "raw": op, "autonomousAvailable": op_avail},
            "route": {"state": ROUTE_STATE.get(rstate, "UNKNOWN"), "raw": rstate,
                      "trajPoints": ntraj, "trajPath": traj_path},
            "vehicle": {"steerDeg": steer_deg, "turn": blink, "mrm": mrm,
                        "plannedKmh": planned_kmh},
            "sensors": sensors, "parts": parts, "faults": faults,
            "sensorSuite": {"lidars": len(ROII_LIDARS), "radars": len(ROII_RADARS),
                            "simulated": 4, "cameras": 0},
            "cmdResult": cmd_res,
        }


CLIENTS = set()
BRIDGE = None


async def handler(ws):
    CLIENTS.add(ws)
    print(f"[+] app connected ({len(CLIENTS)})")
    # one-time lane map for the tablet's 2D Tesla-style map (downsampled)
    try:
        if BRIDGE and BRIDGE.centerlines:
            cl = BRIDGE.centerlines
            step = max(1, len(cl) // 4000)
            lanes = [[round(x, 1), round(y, 1)] for x, y, _ in cl[::step]]
            await ws.send(json.dumps({"type": "lanes", "pts": lanes,
                                      "polys": BRIDGE.lane_polys}))
    except Exception as e:
        print("lanes send error:", e)
    try:
        async for msg in ws:
            try:
                data = json.loads(msg)
                cmd = data.get("cmd")
                if not BRIDGE:
                    continue
                if cmd == "teleop":
                    BRIDGE.set_teleop(data.get("v", 0.0), data.get("steer", 0.0))
                elif cmd == "goto":
                    BRIDGE.enqueue(("goto", data.get("x"), data.get("y")))
                    print(f"[cmd] goto {data.get('x')},{data.get('y')}")
                elif cmd == "vehicle":
                    BRIDGE.enqueue(("vehicle", data.get("model", "roii")))
                    print(f"[cmd] vehicle {data.get('model')}")
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
