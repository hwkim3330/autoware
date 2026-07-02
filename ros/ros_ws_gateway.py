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
import asyncio, json, math, time, threading, datetime, re, os, logging
from collections import deque

import rclpy
from rclpy.node import Node
from rclpy.clock import Clock, ClockType
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
from autoware_vehicle_msgs.srv import ControlModeCommand
from autoware_adapi_v1_msgs.msg import ManualOperatorHeartbeat
from tier4_control_msgs.msg import GateMode
from tier4_vehicle_msgs.msg import VehicleEmergencyStamped
from tier4_control_msgs.srv import SetPause

WS_HOST, WS_PORT, WS_PATH = "0.0.0.0", 8765, "/ws"
# The tablet/adb-reverse churn opens TCP probes that never finish the WS handshake;
# the websockets lib handles them fine (server keeps running) but logs a full
# traceback each time, flooding gw.log and looking like the gateway "broke". These
# are benign -> silence the handshake-failure logger so real messages stay visible.
logging.getLogger("websockets.server").setLevel(logging.CRITICAL)
logging.getLogger("websockets").setLevel(logging.CRITICAL)
MAP_OSM = os.environ.get("LANELET_OSM", "/root/autoware_map/Town01/lanelet2_map.osm")
# CARLA spawn "x, y, z, roll, pitch, yaw" (CARLA coords) -- for the respawn cmd
CARLA_SPAWN = os.environ.get("CARLA_SPAWN", "")
RVIZ_DISPLAY = os.environ.get("RVIZ_DISPLAY", ":1")
# Map geo-origin (lat,lon) + site name so the tablet can place the local map-frame
# ego on a real OpenStreetMap basemap. Set by the OSM/real-map bring-up.
#   NIRO_ORIGIN="lat,lon"   NIRO_SITE="soongsil"
def _parse_origin():
    o = os.environ.get("NIRO_ORIGIN", "")
    try:
        la, lo = [float(v) for v in o.split(",")[:2]]
        return {"lat": la, "lon": lo, "site": os.environ.get("NIRO_SITE", "")}
    except Exception:
        return None
MAP_ORIGIN = _parse_origin()
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
        return [], [], {}
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
    lane_by_id = {}   # lanelet_id -> full centerline polyline (for full route)
    for m in re.finditer(r'<relation id="(-?\d+)"[^>]*>(.*?)</relation>', txt, re.S):
        lid = m.group(1)
        b = m.group(2)
        if 'v="lanelet"' not in b:
            continue
        members = {}
        for mm in re.finditer(r'<member\b([^>]*)>', b):
            attrs = mm.group(1)
            role = re.search(r'role="([^"]+)"', attrs)
            ref = re.search(r'ref="(-?\d+)"', attrs)
            if role and ref:
                members[role.group(1)] = ref.group(1)
        left_ref = members.get("left")
        right_ref = members.get("right")
        if not (left_ref and right_ref and left_ref in wy and right_ref in wy):
            continue
        l, r = wy[left_ref], wy[right_ref]
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
        ds = [[round(p[0], 1), round(p[1], 1)] for p in poly]
        polys.append(ds)
        lane_by_id[lid] = ds
    return pts, polys, lane_by_id


def load_traffic_lights(path):
    """Map a TrafficLightGroupArray's traffic_light_group_id -> (x,y,z) position.
    In the lanelet2 map a `regulatory_element` relation (subtype=traffic_light) is the
    group; its `refers` member is a `traffic_light` way whose nodes give the light-bar
    location. The group id reported by AWSIM == the relation id (we also index by the
    traffic_light way id as a fallback)."""
    try:
        txt = open(path).read().replace("'", '"')
    except Exception:
        return {}
    nd = {}
    for m in re.finditer(r'<node id="(-?\d+)"[^>]*>(.*?)</node>', txt, re.S):
        b = m.group(2)
        x = re.search(r'k="local_x" v="([-\d.]+)"', b)
        y = re.search(r'k="local_y" v="([-\d.]+)"', b)
        zt = re.search(r'k="ele" v="([-\d.]+)"', b)
        if x and y:
            nd[m.group(1)] = (float(x.group(1)), float(y.group(1)),
                              float(zt.group(1)) if zt else 5.0)
    # traffic_light ways -> centroid of their nodes (the light bar)
    way_pos = {}
    for m in re.finditer(r'<way id="(-?\d+)"[^>]*>(.*?)</way>', txt, re.S):
        b = m.group(2)
        if 'v="traffic_light"' not in b:
            continue
        refs = [r for r in re.findall(r'<nd ref="(-?\d+)"', b) if r in nd]
        if refs:
            n = len(refs)
            way_pos[m.group(1)] = (sum(nd[r][0] for r in refs) / n,
                                   sum(nd[r][1] for r in refs) / n,
                                   max(nd[r][2] for r in refs))
    out = dict(way_pos)   # index by traffic_light way id (fallback)
    # regulatory_element relations (subtype traffic_light): relation id == group id
    for m in re.finditer(r'<relation id="(-?\d+)"[^>]*>(.*?)</relation>', txt, re.S):
        b = m.group(2)
        if 'v="traffic_light"' not in b or 'v="regulatory_element"' not in b:
            continue
        refs = []
        for mm in re.finditer(r'<member\b([^>]*)>', b):
            a = mm.group(1)
            role = re.search(r'role="([^"]+)"', a)
            ref = re.search(r'ref="(-?\d+)"', a)
            if role and ref and role.group(1) == "refers":
                refs.append(ref.group(1))
        ps = [way_pos[r] for r in refs if r in way_pos]
        if ps:
            out[m.group(1)] = (sum(p[0] for p in ps) / len(ps),
                               sum(p[1] for p in ps) / len(ps),
                               max(p[2] for p in ps))
    return out


def synth_tl_color(x, y, t):
    """Synthetic traffic-light phase for a light at (x,y). AWSIM-Demo's Shinjuku scene
    publishes an EMPTY signals topic (no live red/green), so we drive the REAL map lights
    on a believable cycle: lights are clustered per ~38 m intersection cell and offset so
    different junctions are out of phase. 22 s cycle: green 0-12, amber 12-14, red 14-22.
    Returns 1=RED 2=AMBER 3=GREEN."""
    cell = (round(x / 38.0), round(y / 38.0))
    off = (abs(cell[0] * 73856093 ^ cell[1] * 19349663) % 22)
    ph = (t + off) % 22
    if ph < 12:
        return 3
    if ph < 14:
        return 2
    return 1


class Bridge(Node):
    def __init__(self):
        super().__init__("roii_ws_gateway")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.lock = threading.Lock()
        self.s = {}
        self.lidar_t = []
        self.cmds = deque()
        self.last_cmd_result = ""
        self.centerlines, self.lane_polys, self.lane_by_id = load_centerlines(MAP_OSM)
        self.tlpos = load_traffic_lights(MAP_OSM)   # group_id -> (x,y,z) of the light
        # deduped physical light positions (the map indexes each light by both its way id
        # and its regulatory-element id -> same spot twice). Used to render/phase lights.
        _seen = set(); self.tl_points = []
        for (x, y, z) in self.tlpos.values():
            key = (round(x, 0), round(y, 0))
            if key in _seen:
                continue
            _seen.add(key); self.tl_points.append((x, y, z))
        self.route_path = []   # full route to goal (lanelet centerlines), for the app
        self.get_logger().info(
            f"loaded {len(self.centerlines)} centerline points, {len(self.lane_polys)} lane polylines")

        tl = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                        reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 lambda m: self._set("odom", m), 10)
        # Multimode (이중측위): LiDAR-only vs GNSS-only localization, published separately by
        # the pose_twist_fusion_filter. Forwarded so the tablet can show both + their gap.
        be2 = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(Odometry, "/localization/pose_twist_fusion_filter/lidar/kinematic_state",
                                 lambda m: self._set("odom_lidar", m), be2)
        self.create_subscription(Odometry, "/localization/pose_twist_fusion_filter/gnss/kinematic_state",
                                 lambda m: self._set("odom_gnss", m), be2)
        # Live raw GNSS pose (gnss_poser, map frame) — the live-and-bag common GNSS
        # source (the dual gnss/lidar sub-EKF topics only exist in the Soongsil bag).
        from geometry_msgs.msg import PoseWithCovarianceStamped as _PCS
        self.create_subscription(_PCS, "/sensing/gnss/pose_with_covariance",
                                 lambda m: self._set("gnss_raw", m), be2)
        # GNSS fault injector output (possibly drifted/dropped/jumped). When the
        # injector runs, the multimode gap prefers it so a GNSS fault visibly grows
        # the gap; drop -> stale -> GNSS shown LOST.
        self.create_subscription(_PCS, "/roii/gnss/pose_with_covariance",
                                 lambda m: self._set("odom_gnss_inj", m), be2)
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
        # Niro multimode telemetry (단일 Ouster OS2-128 + RTK-GNSS 이중측위).
        # niro_bridge runs the Niro-spec Pose Merger live on the CARLA topics.
        self.create_subscription(_Str, "/niro/multimode/status",
                                 lambda m: self._set("niro_status", m), 1)
        self.create_subscription(_Str, "/niro/multimode/transition_event",
                                 lambda m: self._set("niro_event", m), 5)
        from std_msgs.msg import Bool as _Bool
        self.pub_niro_fault = self.create_publisher(_Bool, "/test/fault_injection/lidar", 1)
        # ROii 4-LiDAR experimental layer
        self.create_subscription(_Str, "/roii/lidar_health",
                                 lambda m: self._set("roii_health", m), 1)
        # 장애 감지·재구성: injector status 구독 → gateway 내부에서 reconfig 계산
        self.create_subscription(_Str, "/roii/fault_injector/status",
                                 lambda m: self._set("inj_status", m), 1)
        self._reconfig_mode = "NORMAL"
        self._reconfig_settled = False  # 부팅 직후 topic 미도착 구간의 오탐 이력 방지
        self._reconfig_history = []
        import collections as _col
        self._reconfig_hist_deq = _col.deque(maxlen=20)
        # Fault detector: 센서·모듈 장애 감지 결과
        self.create_subscription(_Str, "/roii/fault_report",
                                 lambda m: self._set("fault_report", m), 1)
        # Reconfig manager: 주행 모드·재구성 상태 (태블릿 시각화 핵심)
        self.create_subscription(_Str, "/roii/reconfig_status",
                                 lambda m: self._set("reconfig_status", m), 1)
        self.pub_roii_fault = self.create_publisher(_Str, "/roii/fault_injector/command", 10)
        self.pub_gnss_fault = self.create_publisher(_Str, "/roii/gnss_fault/command", 10)
        self._gnss_fault = "normal"   # last GNSS fault mode we injected (for status/UI)
        # full route to the goal (lanelet sequence) for the tablet — the whole
        # path to the destination, not just the local trajectory.
        try:
            from autoware_planning_msgs.msg import LaneletRoute
            self.create_subscription(LaneletRoute, "/planning/mission_planning/route",
                                     self._on_route, tl)
        except Exception:
            pass
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
        # front-camera frames for the tablet popup (YOLOX overlay if running, else
        # the raw camera). Throttled + downscaled + JPEG-encoded in the callback;
        # the camera_producer() coroutine ships the latest frame at ~6 Hz.
        self._jpg = None; self._jpg_t = 0.0
        from sensor_msgs.msg import Image as _Img
        for topic in ("/tensorrt_yolox/out/image", "/sensing/camera/camera0/image_rect_color"):
            self.create_subscription(_Img, topic, self._cam_cb, be)
        # Traffic-light recognition from AWSIM's traffic_light camera. AWSIM-Demo gives
        # NO signal states over ROS (V2I + /perception/...signals are empty), so we read
        # the ACTUAL rendered light off the camera image -> the tablet matches the sim and
        # the car stops on the real red. Detected colour: 1=RED 2=AMBER 3=GREEN, 0=none.
        self._cam_tl_color = 0; self._cam_tl_t = 0.0
        self.create_subscription(_Img, "/sensing/camera/traffic_light/image_raw",
                                 self._tl_cam_cb, be)
        # per-LiDAR liveness (ROii 4-lidar suite; in 1-lidar mode only front maps)
        self.lidar_part_t = {k: [] for k in
                             ("front", "rear", "side_left", "side_right")}
        for key in self.lidar_part_t:
            self.create_subscription(
                PointCloud2, f"/sensing/lidar/{key}/pointcloud_before_sync",
                (lambda k: lambda m: self._part_tick(k))(key), be)
        # Detected objects for the tablet map. Two sources, whichever is live:
        #  - full perception (PERCEPTION=1): /perception/object_recognition/objects
        #    = tracked+predicted PredictedObjects (map frame, classified).
        #  - opt-in CenterPoint (CENTERPOINT=1): /perception/centerpoint/objects
        #    = DetectedObjects in base_link.
        try:
            from autoware_perception_msgs.msg import DetectedObjects
            self.create_subscription(DetectedObjects, "/perception/centerpoint/objects",
                                     lambda m: self._set("objs", m), be)
            self.create_subscription(PredictedObjects, "/perception/object_recognition/objects",
                                     lambda m: self._set("pobjs", m), be)
        except Exception:
            pass
        # Traffic-light signals (AWSIM ground truth, ~19 Hz). Forwarded to the tablet for
        # the Tesla-style upcoming-light display; also drives the planner's red-light stop.
        try:
            from autoware_perception_msgs.msg import TrafficLightGroupArray
            self.create_subscription(TrafficLightGroupArray,
                                     "/perception/traffic_light_recognition/traffic_signals",
                                     lambda m: self._set("tls", m), be)
        except Exception:
            pass
        # External velocity limit -> lets us stop the car for a red light (the planner
        # decelerates smoothly to it). AWSIM gives no signal states, so the synthetic
        # red light ahead drives this. tl QoS = transient_local (the selector latches).
        self.vlim_pub = None
        try:
            from tier4_planning_msgs.msg import VelocityLimit
            self._VelocityLimit = VelocityLimit
            qos_tl = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                                durability=DurabilityPolicy.TRANSIENT_LOCAL,
                                history=HistoryPolicy.KEEP_LAST)
            self.vlim_pub = self.create_publisher(
                VelocityLimit, "/planning/scenario_planning/max_velocity_default", qos_tl)
        except Exception:
            pass
        self._vlim_now = None      # last published limit (m/s), avoid needless spam
        self.NORMAL_VLIM = 11.0    # ~40 km/h cruise
        cbg = ReentrantCallbackGroup()
        self.cli_clear = self.create_client(ClearRoute, "/api/routing/clear_route", callback_group=cbg)
        self.cli_route = self.create_client(SetRoutePoints, "/api/routing/set_route_points", callback_group=cbg)
        self.cli_auto = self.create_client(ChangeOperationMode, "/api/operation_mode/change_to_autonomous", callback_group=cbg)
        self.cli_stop = self.create_client(ChangeOperationMode, "/api/operation_mode/change_to_stop", callback_group=cbg)
        # NDT/EKF 강제 재초기화용 (respawn 안정화): 끄고 -> initialpose -> 다시 켜면
        # 이전 세션의 잔여 내부 상태(속도/공분산 이력)를 안고 가지 않고 완전히 새로 정렬한다.
        from std_srvs.srv import SetBool
        self.cli_trig_ndt = self.create_client(SetBool, "/localization/pose_estimator/trigger_node", callback_group=cbg)
        self.cli_trig_ekf = self.create_client(SetBool, "/localization/pose_twist_fusion_filter/trigger_node", callback_group=cbg)
        self._emergency = False   # set by trigger_emergency, cleared by heal/drive
        self._cmd_clock = Clock(clock_type=ClockType.SYSTEM_TIME)
        self.create_timer(0.5, self._process_cmds, callback_group=cbg)
        # ---- manual teleop (joystick) ----
        # External (manual joystick) control path: gate EXTERNAL + unpause, then
        # publish to /external/selected/* which the gate forwards to the vehicle.
        # Direct injection onto the interface's control input (proven to move the
        # ego). We are a second publisher on the gate-output topic; at high rate we
        # win the contention enough to drive. Plus arm the gate EXTERNAL+unpause so
        # the gate itself stops emitting brake.
        cmd_qos = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                             reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
        self.pub_ctrl = self.create_publisher(Control, "/control/command/control_cmd", cmd_qos)
        self.pub_gate = self.create_publisher(GateMode, "/control/gate_mode_cmd", 1)
        self.pub_gear = self.create_publisher(GearCommand, "/control/command/gear_cmd", cmd_qos)
        self.pub_emergency_cmd = self.create_publisher(
            VehicleEmergencyStamped, "/control/command/emergency_cmd", cmd_qos)
        # Manual control bypasses the cmd_gate by publishing actuation directly to
        # the CARLA interface (verified to move the ego). Reverse uses a dedicated
        # latch the gate can't override (gear_cmd is contended by the gate's PARK).
        from tier4_vehicle_msgs.msg import ActuationCommandStamped as _Act
        from std_msgs.msg import Bool as _Bool
        self.pub_act = self.create_publisher(_Act, "/control/command/actuation_cmd", 1)
        self.pub_manrev = self.create_publisher(_Bool, "/roii/manual_reverse", 1)
        self._Act, self._Bool = _Act, _Bool
        self.cli_pause = self.create_client(SetPause, "/control/vehicle_cmd_gate/set_pause", callback_group=cbg)
        self.cli_control_mode = self.create_client(
            ControlModeCommand, "/input/control_mode_request", callback_group=cbg)
        self.teleop = {"v": 0.0, "steer": 0.0, "until": 0.0}
        self._teleop_armed = False
        self.create_timer(0.01, self._teleop_tick, callback_group=cbg)  # sim-time backup
        threading.Thread(target=self._teleop_wall_loop, daemon=True).start()
        # CARLA direct-control backup is only for CARLA launches. In AWSIM it
        # repeatedly times out on port 2000 and can starve manual ROS publishing.
        self._carla_lock = threading.Lock()
        self._carla_direct = os.environ.get("ENABLE_CARLA_DIRECT", "0") == "1" or bool(CARLA_SPAWN)
        if self._carla_direct:
            threading.Thread(target=self._carla_loop, daemon=True).start()

    def _arm_teleop(self):
        for _ in range(3):
            self.pub_gate.publish(GateMode(data=1)); time.sleep(0.01)
        try:
            req = SetPause.Request(); req.pause = False
            self.cli_pause.call_async(req)
        except Exception:
            pass
        try:
            if self.cli_control_mode.wait_for_service(timeout_sec=0.2):
                req = ControlModeCommand.Request()
                req.mode = ControlModeCommand.Request.AUTONOMOUS
                self.cli_control_mode.call_async(req)
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
        """Lazy CARLA client + ego handle for direct manual control.

        Reverse only works when this returns the actor; if it returns None the
        manual loop is skipped and the Autoware chain just BRAKES on negative
        velocity (no backward motion). So the lookup must be robust: accept
        several role_names, fall back to the sole vehicle, and -- crucially --
        wait_for_tick() because a second sync-mode client's get_actors() can come
        back empty until the world ticks."""
        try:
            import carla
            if not hasattr(self, "_carla_cl"):
                self._carla_cl = carla.Client("localhost", 2000)
                self._carla_cl.set_timeout(5.0)
                self._carla_mod = carla
            ego = getattr(self, "_carla_ego_a", None)
            if ego is not None and ego.is_alive:
                return ego
            world = self._carla_cl.get_world()
            try:
                world.wait_for_tick(2.0)   # sync-mode: actors empty until a tick
            except Exception:
                pass
            vehicles = list(world.get_actors().filter("vehicle.*"))
            ego = next((a for a in vehicles
                        if a.attributes.get("role_name") in ("ego_vehicle", "hero", "ego")), None)
            if ego is None and len(vehicles) == 1:
                ego = vehicles[0]            # only one vehicle -> it's the ego
            self._carla_ego_a = ego
            if ego is None:
                self.get_logger().warn(
                    f"_carla_ego: no ego among {len(vehicles)} vehicles "
                    f"(roles={[a.attributes.get('role_name') for a in vehicles]}) -- reverse disabled")
            return ego
        except Exception as e:
            self.get_logger().warn(f"_carla_ego error: {e}")
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

    def _teleop_wall_loop(self):
        while True:
            time.sleep(0.05)
            self._teleop_tick()

    def _teleop_tick(self):
        with self.lock:
            tp = dict(self.teleop)
        if time.monotonic() > tp["until"]:
            self._teleop_armed = False
            return
        now = self._cmd_clock.now().to_msg()
        e = VehicleEmergencyStamped(); e.stamp = now
        e.emergency = False
        self.pub_emergency_cmd.publish(e)
        g = GearCommand(); g.stamp = now
        g.command = 20 if tp["v"] < -0.01 else 2   # 20=REVERSE, 2=DRIVE
        c = Control(); c.stamp = now
        # AWSIM uses ONLY longitudinal.acceleration (ignores velocity) and, in Gear.Reverse,
        # applies ApplyWheelForce(-a) -> it NEGATES the accel. So reverse needs a POSITIVE
        # acceleration to thrust backward (a negative one becomes forward thrust -> won't
        # reverse). Forward (Gear.Drive) uses +a as-is. (AccelVehicle.cs L431-437.)
        c.longitudinal.velocity = abs(tp["v"])
        # In Gear.Reverse AWSIM negates accel (force=-a), so reverse needs a POSITIVE value
        # to thrust backward. Reverses cleanly from a stopped/PARK state; reversing right
        # after forward driving can be flaky (gate gear/hold interaction).
        c.longitudinal.acceleration = 4.0 if tp["v"] > 0 else (4.0 if tp["v"] < 0 else 0.0)
        c.lateral.steering_tire_angle = tp["steer"]
        # Direct path: gear + control straight to the topics AWSIM reads (gate bypass).
        # Reverses from a clean stop (verified 23m). Can be flaky right after forward
        # driving due to the gate's gear output flickering DRIVE<->REVERSE.
        self.pub_gear.publish(g)
        self.pub_ctrl.publish(c)
        rev = tp["v"] < -0.05
        # Dedicated reverse latch -> interface (gear_cmd is overridden by the
        # gate's PARK, so this is what actually flips CARLA into reverse).
        b = self._Bool(); b.data = bool(rev); self.pub_manrev.publish(b)
        # Publish actuation DIRECTLY to the interface (bypasses the cmd_gate,
        # which parks/brakes when not engaged). accel for forward; for reverse
        # send brake_cmd -- the interface's reverse patch maps brake->throttle
        # when the reverse latch is set. Verified to move the ego both ways.
        if not self._carla_direct:
            return
        mag = min(abs(tp["v"]) / 6.0, 1.0) * 0.6
        a = self._Act(); a.header.stamp = now
        if abs(tp["v"]) < 0.05:
            a.actuation.accel_cmd = 0.0; a.actuation.brake_cmd = 0.4
        elif rev:
            a.actuation.accel_cmd = 0.0; a.actuation.brake_cmd = mag
        else:
            a.actuation.accel_cmd = mag; a.actuation.brake_cmd = 0.0
        a.actuation.steer_cmd = tp["steer"]
        self.pub_act.publish(a)
        # Direct CARLA control also runs in a DEDICATED thread (_carla_loop) as a
        # backup; libcarla is not thread-safe so it must not be called here.

    def _set(self, k, m):
        with self.lock:
            self.s[k] = (m, time.monotonic())

    def _on_route(self, msg):
        """Build the FULL route polyline (goal -> ego) from the route's lanelet
        segments, looked up in the osm centerline map. Sent to the tablet so it
        draws the complete path to the destination, not just the local trajectory."""
        path = []
        try:
            for seg in msg.segments:
                lid = str(seg.preferred_primitive.id)
                poly = self.lane_by_id.get(lid) or self.lane_by_id.get(str(-int(lid)))
                if poly:
                    path.extend(poly)
        except Exception:
            pass
        with self.lock:
            self.route_path = path

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

    def _tl_cam_cb(self, m):
        # Detect the dominant traffic-light bulb colour in the upper region of the
        # traffic_light camera (bright, saturated red/amber/green blob). Throttled ~3 Hz.
        now = time.monotonic()
        if now - self._cam_tl_t < 0.33:
            return
        self._cam_tl_t = now
        try:
            import numpy as np
            h, w = m.height, m.width
            buf = np.frombuffer(bytes(m.data), dtype=np.uint8)
            if m.encoding == "bgr8":
                img = buf.reshape((h, w, 3)); B, G, R = img[:, :, 0], img[:, :, 1], img[:, :, 2]
            elif m.encoding == "rgb8":
                img = buf.reshape((h, w, 3)); R, G, B = img[:, :, 0], img[:, :, 1], img[:, :, 2]
            else:
                return
            top = slice(0, int(h * 0.6))
            R = R[top].astype(int); G = G[top].astype(int); B = B[top].astype(int)
            red = int(((R > 170) & (R - G > 70) & (R - B > 70)).sum())
            grn = int(((G > 165) & (G - R > 50) & (G - B > 40)).sum())
            yel = int(((R > 185) & (G > 165) & (R - B > 90) & (G - B > 80) & (abs(R - G) < 55)).sum())
            best = max((red, 1), (yel, 2), (grn, 3), key=lambda x: x[0])
            self._cam_tl_color = best[1] if best[0] > 40 else 0
        except Exception:
            pass

    def _cam_cb(self, m):
        # throttle ~6 Hz; downscale to ~360 px wide; JPEG-encode for the tablet.
        now = time.monotonic()
        if now - self._jpg_t < 0.16:
            return
        try:
            import numpy as np, cv2, base64
            h, w = m.height, m.width
            buf = np.frombuffer(bytes(m.data), dtype=np.uint8)
            if m.encoding in ("rgb8", "bgr8"):
                img = buf.reshape((h, w, 3))
                if m.encoding == "rgb8":
                    img = img[:, :, ::-1]
            elif m.encoding in ("bgra8", "rgba8"):
                img = buf.reshape((h, w, 4))[:, :, :3]
                if m.encoding == "rgba8":
                    img = img[:, :, ::-1]
            else:
                return
            tw = 360; th = max(1, int(h * tw / max(1, w)))
            small = cv2.resize(img, (tw, th), interpolation=cv2.INTER_AREA)
            ok, jpg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 55])
            if ok:
                self._jpg = base64.b64encode(jpg.tobytes()).decode("ascii")
                self._jpg_t = now
        except Exception:
            pass

    def enqueue(self, cmd):
        # Latest intent wins: a new command REPLACES anything still queued
        # (taps piling up made the gateway feel unresponsive for minutes).
        with self.lock:
            self.cmds.clear()
            self.cmds.append(cmd)

    def cmd_loop(self):
        # Drain commands on a WALL-CLOCK thread, not the ROS timer: planning_sim
        # publishes no /clock, so with use_sim_time the ROS timer freezes and NO
        # app command runs. This loop is clock-independent; _call's futures are
        # still serviced by the spinning executor. (CARLA path also benefits.)
        while True:
            try:
                self._process_cmds()
            except Exception as e:
                self.get_logger().warn(f"cmd_loop: {e}")
            time.sleep(0.2)

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
                from std_msgs.msg import String as _Str, Bool as _Bool
                self.pub_inject.publish(_Str(data="lidar_fail"))
                self.pub_niro_fault.publish(_Bool(data=True))   # Niro bridge fallback
                self._res("FAULT INJECTED: lidar -> multimode fallback")
            elif isinstance(cmd, tuple) and cmd[0] == "roii_fault":
                from std_msgs.msg import String as _Str
                self.pub_roii_fault.publish(_Str(data=cmd[1]))
                self._res(f"roii fault cmd: {cmd[1][:60]}")
            elif isinstance(cmd, tuple) and cmd[0] == "gnss_fault":
                from std_msgs.msg import String as _Str
                import json as _json
                try:
                    self._gnss_fault = _json.loads(cmd[1]).get("mode", "normal")
                except Exception:
                    self._gnss_fault = "normal"
                self.pub_gnss_fault.publish(_Str(data=cmd[1]))
                self._res(f"GNSS fault -> {self._gnss_fault}")
            elif cmd == "trigger_emergency":
                # Controlled emergency stop: switch the operation mode to STOP
                # (the ADAPI-blessed hard stop). Latch _emergency so the frame
                # reports it to the tablet as a red banner until healed/driven.
                self._emergency = True
                self._call(self.cli_stop, ChangeOperationMode.Request(), timeout=6.0)
                self._res("EMERGENCY STOP")
            elif cmd == "heal":
                from std_msgs.msg import String as _Str, Bool as _Bool
                self.pub_inject.publish(_Str(data="clear"))
                self.pub_niro_fault.publish(_Bool(data=False))   # Niro bridge clear
                import json as _json
                self.pub_gnss_fault.publish(_Str(data=_json.dumps({"mode": "normal"})))
                self._gnss_fault = "normal"
                # LiDAR injector: heal은 재구성 사다리 전체(4-LiDAR + GNSS)를
                # 정상으로 되돌리는 단일 버튼이어야 하므로 여기서도 clear.
                self.pub_roii_fault.publish(_Str(data=_json.dumps({"sensor": "all", "mode": "normal"})))
                self._emergency = False
                self._res("fault cleared -> auto mode selection")
            elif isinstance(cmd, tuple) and cmd[0] == "vehicle":
                self._vehicle(cmd[1])
            elif isinstance(cmd, tuple) and cmd[0] == "maxvel":
                self._set_maxvel(cmd[1])
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
        self._emergency = False    # a new drive clears a prior emergency stop
        with self.lock:
            od = self.s.get("odom")
        if not od:
            self._res("no localization"); return
        o = od[0].pose.pose
        ex, ey, q = o.position.x, o.position.y, o.orientation
        eyaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        # candidate goals AHEAD (within ~75 deg of heading), nearest first.
        # Wide distance band (25-160m): on some maps the only routable goal is
        # close (short lanes/junctions, e.g. Town02) or far (long straights,
        # e.g. Town05/Town10HD), so we no longer assume one sweet spot.
        ahead, anyd = [], []
        for x, y, tg in self.centerlines:
            d = math.hypot(x - ex, y - ey)
            if not (25 < d < 160):
                continue
            anyd.append((d, x, y, tg))
            ang = math.atan2(y - ey, x - ex)
            if abs((ang - eyaw + math.pi) % (2 * math.pi) - math.pi) < 1.3:
                ahead.append((d, x, y, tg))
        ahead.sort(); anyd.sort()

        # Spread attempts across the band instead of clustering: goals at 55%,
        # 75%, 35%, 90%... of the sorted distance range, then fill with the rest.
        # Many maps reject the obvious near goal but accept one farther up the
        # same road -- so we try generously (these rejects are fast, ~0.3s).
        def ordered(cand):
            out, seen, n = [], set(), len(cand)
            picks = [int(n * f) for f in (0.55, 0.75, 0.35, 0.9, 0.15, 0.5, 0.25, 0.7)]
            for i in picks + list(range(n)):
                if 0 <= i < n and i not in seen:
                    seen.add(i); out.append(cand[i])
            return out

        # Pass 1: goals AHEAD of the heading (route best when the spawn faces
        # the lane). Pass 2: ANY-direction goals -- covers spawns whose heading
        # is anti-parallel to the lane (Town10HD), where every "ahead" point
        # sits on an unreachable/oncoming lanelet but a behind/side goal routes.
        self._res(f"finding route ({len(ahead)} ahead / {len(anyd)} any)")
        self._prep_reroute()
        for pool, take in ((ahead, 14), (anyd, 16)):
            for d, gx, gy, gtg in ordered(pool)[:take]:
                # try the stored tangent AND its 180-deg flip: converted maps may
                # store boundary roles swapped, so the tangent can be anti-parallel
                # to the lane -- the planner rejects those instantly (cheap retry).
                for g2 in (gtg, gtg + math.pi):
                    r = self._set_route_to(gx, gy, g2, timeout=6.0)
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

    def _prep_reroute(self):
        """Re-routing while AUTONOMOUS crashes behavior_planning (it resets its
        modules while the trajectory follower is mid-use -> rclcpp guard race).
        Quiesce first: STOP -> wait for the ego to actually halt -> clear. Only
        does the heavy quiesce when a route is already active."""
        with self.lock:
            op = self.s.get("op")
            already = bool(self.s.get("route") and self.s["route"][0].state in (2, 4))
        if already or (op and op[0].mode == 2):   # SET/CHANGING or AUTONOMOUS
            self._res("re-route: stopping first")
            try:
                self._call(self.cli_stop, ChangeOperationMode.Request(), timeout=6.0)
            except Exception:
                pass
            # wait for the ego to come to rest so the follower releases the path
            for _ in range(20):
                time.sleep(0.3)
                with self.lock:
                    od = self.s.get("odom")
                if od:
                    v = od[0].twist.twist.linear
                    if math.hypot(v.x, v.y) < 0.2:
                        break
            time.sleep(0.5)
        self._call(self.cli_clear, ClearRoute.Request(), timeout=4.0)

    def _engage(self, gx, gy):
        tag = f" ({gx:.0f},{gy:.0f})" if gx is not None else ""
        self._res(f"route set{tag}; engaging")
        # Trajectory generation + autonomous AVAILABILITY can take 15-25 s on big
        # real maps. Wait for availability first (cheap topic check), THEN engage;
        # retry up to ~40 s so tap-to-go succeeds first try (was a fixed 12 s window
        # that timed out before the planner finished -> "target mode not available").
        ra = None
        for i in range(20):
            with self.lock:
                op = self.s.get("op")
            avail = bool(op and op[0].is_autonomous_mode_available) if op else False
            if avail:
                ra = self._call(self.cli_auto, ChangeOperationMode.Request())
                if ra and ra.status.success:
                    self._res("AUTONOMOUS"); return
            if i % 3 == 0:
                self._res(f"engaging... ({i + 1}/20){' (waiting for trajectory)' if not avail else ''}")
            time.sleep(2.0)
        self._res(f"route set, engage failed: {ra.status.message if ra else 'availability timeout'}")

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
        self._prep_reroute()
        # 1) try the tapped spot itself: the nearest distinct centerline points
        #    around the tap (within 18 m), each with its lane tangent + flip.
        #    A single snap point often lands on a goal-ineligible lanelet
        #    (intersection interior / opposing lane); trying several nearby
        #    points on real lanes makes "go exactly where I tapped" land.
        near = []
        for x, y, tg in ranked:
            d = math.hypot(x - tx, y - ty)
            if d > 18:
                break
            if all(math.hypot(x - q[0], y - q[1]) > 4.0 for q in near):
                near.append((x, y, tg))
            if len(near) >= 8:
                break
        # Order goal-orientations so the AHEAD-of-ego direction is tried first.
        # A goal behind the ego (or its lane tangent pointing back) makes the
        # planner emit a REVERSE trajectory; lane-driving won't reverse on roads
        # so the car just sits. Prefer the orientation whose heading points
        # roughly the same way as ego->goal travel.
        with self.lock:
            od0 = self.s.get("odom")
        eyaw0 = None
        if od0:
            q0 = od0[0].pose.pose.orientation
            eyaw0 = math.atan2(2 * (q0.w * q0.z + q0.x * q0.y),
                               1 - 2 * (q0.y * q0.y + q0.z * q0.z))
        for cx2, cy2, ct in near:
            orients = (ct, ct + math.pi)
            if eyaw0 is not None:
                # goal heading closest to ego heading first (forward-consistent)
                orients = sorted(orients,
                    key=lambda a: abs((a - eyaw0 + math.pi) % (2 * math.pi) - math.pi))
            for g2 in orients:
                r = self._set_route_to(cx2, cy2, g2, timeout=6.0)
                if (r and r.status.success) or self._route_is_set():
                    self._engage(cx2, cy2); return
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
        """Recover the ego onto the road after a crash / off-lane drift, without
        a full relaunch. Tries the validated fixed spawn FIRST (NDT converges
        reliably there), then the nearest lane centerline as a fallback. NDT can
        diverge when re-seeded at an arbitrary point, so each target is verified
        and we move on if it doesn't converge."""
        # STOP + clear ONCE so autonomous doesn't drive the teleported car away.
        try:
            self._call(self.cli_stop, ChangeOperationMode.Request(), timeout=6.0)
        except Exception:
            pass
        self._call(self.cli_clear, ClearRoute.Request(), timeout=4.0)
        time.sleep(1.0)
        # candidate CARLA poses (x,y,z,roll,pitch,yaw), reliable first
        cands = []
        if CARLA_SPAWN:
            cands.append(("spawn", [float(v) for v in CARLA_SPAWN.split(",")]))
        with self.lock:
            od = self.s.get("odom")
        if od and self.centerlines:
            o = od[0].pose.pose
            ex, ey = o.position.x, o.position.y
            ax, ay, atan = min(self.centerlines,
                               key=lambda c: math.hypot(c[0] - ex, c[1] - ey))
            cands.append(("nearest-lane", (ax, -ay, 0.5, 0.0, 0.0, -math.degrees(atan))))
        if not cands:
            self._res("respawn: no spawn and no lane/odom"); return
        for label, t in cands:
            self._res(f"recovering via {label}...")
            if self._teleport_to(*t):
                self._res(f"respawn OK ({label}) -- on lane, ready to DRIVE"); return
        self._res("respawn: localization did not converge (try DRIVE or relaunch)")

    def _trigger(self, client, on, timeout=3.0):
        """NDT/EKF trigger_node(SetBool) 호출. 서비스가 없거나 응답이 늦어도
        respawn 흐름 자체는 막지 않도록 예외를 삼킨다."""
        try:
            from std_srvs.srv import SetBool
            if not client.wait_for_service(timeout_sec=timeout):
                return False
            req = SetBool.Request(); req.data = on
            fut = client.call_async(req)
            end = time.monotonic() + timeout
            while not fut.done() and time.monotonic() < end:
                time.sleep(0.05)
            return fut.done()
        except Exception:
            return False

    def _teleport_to(self, x, y, z, roll, pitch, yaw):
        """Recover to a CARLA pose by publishing /initialpose. The CARLA
        interface OWNS the ego and ticks the sim, so its initialpose_callback
        does the actual set_transform (a secondary client's set_transform is
        swallowed in sync mode -- that's what made earlier respawns diverge).
        This is exactly how the bring-up seeds localization, so NDT converges.

        Mid-session respawns are less reliable than the boot-time seed because
        NDT/EKF carry residual internal state (velocity, covariance history)
        from wherever the car just was. Trigger_node(false) -> initialpose ->
        trigger_node(true) forces a full fresh re-align instead of blending
        the new pose with stale state -- same mechanism as RViz's "Initialize
        with GNSS" button. Returns True iff NDT settles within 5 m.
        (x,y,z,...) are CARLA coords."""
        ax, ay = x, -y                 # CARLA -> Autoware (map frame) y-flip
        awyaw = math.radians(-yaw)     # yaw-flip
        from geometry_msgs.msg import PoseWithCovarianceStamped
        if not hasattr(self, "pub_init"):
            self.pub_init = self.create_publisher(PoseWithCovarianceStamped, "/initialpose", 1)
            time.sleep(0.5)

        self._trigger(self.cli_trig_ndt, False)
        self._trigger(self.cli_trig_ekf, False)
        time.sleep(0.5)

        for _ in range(3):
            m = PoseWithCovarianceStamped()
            m.header.frame_id = "map"
            m.header.stamp = self.get_clock().now().to_msg()
            m.pose.pose.position.x = ax
            m.pose.pose.position.y = ay
            m.pose.pose.orientation.z = math.sin(awyaw / 2)
            m.pose.pose.orientation.w = math.cos(awyaw / 2)
            # 재초기화 직후라 이전 상태와 어긋날 수 있으므로 초기 탐색 반경을
            # 조금 넉넉하게 (0.5m/15도 -> 1.5m/25도 표준편차) 잡아 NDT가 로컬
            # 미니멈에 걸리지 않고 실제 위치로 수렴하게 한다.
            m.pose.covariance[0] = m.pose.covariance[7] = 2.25
            m.pose.covariance[35] = 0.19
            self.pub_init.publish(m)
            time.sleep(1.0)

        self._trigger(self.cli_trig_ndt, True)
        self._trigger(self.cli_trig_ekf, True)

        for _ in range(15):
            time.sleep(1.0)
            with self.lock:
                od = self.s.get("odom")
            if od:
                p = od[0].pose.pose.position
                if math.hypot(p.x - ax, p.y - ay) < 5.0:
                    return True
        return False

    def _set_maxvel(self, kmh):
        """Runtime cruise-speed change (no re-launch): set max_vel on the nodes
        that read it. Tablet speed slider -> here."""
        import subprocess
        ms = round(float(kmh) / 3.6, 2)
        targets = [
            ("/planning/scenario_planning/motion_velocity_smoother", "max_vel"),
            ("/planning/scenario_planning/scenario_selector", "max_vel"),
        ]
        done = 0
        for node, param in targets:
            try:
                r = subprocess.run(["ros2", "param", "set", node, param, str(ms)],
                                   capture_output=True, text=True, timeout=6)
                if "Set parameter successful" in (r.stdout + r.stderr):
                    done += 1
            except Exception:
                pass
        # external velocity limit topic (takes effect immediately on the smoother)
        try:
            from autoware_internal_planning_msgs.msg import VelocityLimit
            if not hasattr(self, "pub_vlim"):
                self.pub_vlim = self.create_publisher(
                    VelocityLimit, "/planning/scenario_planning/max_velocity_default", 1)
                time.sleep(0.3)
            m = VelocityLimit()
            m.stamp = self.get_clock().now().to_msg()
            m.max_velocity = float(ms)
            self.pub_vlim.publish(m)
            done += 1
        except Exception as e:
            self.get_logger().warn(f"vlim pub: {e}")
        self._res(f"max speed -> {kmh:.0f} km/h ({done} applied)")

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

    _MODE_DESC = {
        "NORMAL":"전체 센서 정상 — 4-LiDAR 자율주행",
        "DEGRADED_3":"LiDAR 1개 고장 — 3개로 재구성",
        "DEGRADED_2":"LiDAR 2개 고장 — 2개로 재구성",
        "DEGRADED_1":"LiDAR 3개 고장 — 1개로 재구성",
        "GNSS_FALLBACK":"전체 LiDAR 고장 — GNSS 측위 폴백",
        "MODULE_FAULT":"자율주행 모듈 장애", "MRM":"최소위험기동",
    }
    _MODE_PRI = {"NORMAL":0,"DEGRADED_3":1,"DEGRADED_2":2,"DEGRADED_1":3,
                 "GNSS_FALLBACK":4,"MODULE_FAULT":5,"MRM":6}
    _LIDARS_RCG = ("front_g32","rear_g32","left_pandar","right_pandar")

    def _calc_reconfig(self, s, *, ndt_hz=0.0, converged=False, ntraj=0,
                        rstate=0, op_avail=False):
        """injector_status + gnss_fault + 이미 계산된 localization/planning/control
        지표(ndt_hz, converged, ntraj, rstate, op_avail — frame()에서 넘겨받음)로
        재구성 상태 계산. 별도 노드/구독 없이 gateway 내부에서만 판단 (DDS 안전)."""
        import datetime as _dt, json as _json
        try:
            inj = _json.loads(s["inj_status"][0].data) if "inj_status" in s else {}
        except Exception:
            inj = {}
        gfault = getattr(self, "_gnss_fault", "normal")

        sensor_summary, active = {}, 0
        for lid in self._LIDARS_RCG:
            mode = inj.get(lid, {}).get("mode", "normal")
            st = "OK" if mode == "normal" else mode.upper()
            sensor_summary[lid] = {"status": st, "hz": 0.0}
            if mode == "normal":
                active += 1
        sensor_summary["gnss"] = {
            "status": "OK" if gfault == "normal" else gfault.upper(),
            "hz": 0.0, "cov": 0.0}
        sensor_summary["imu"]  = {"status": "OK", "hz": 0.0}

        # 모듈 상태: 이미 frame()이 매 틱 계산하는 지표를 그대로 판정에 사용
        #  - localization: kinematic_state(odom)가 최근 2초 내 갱신됐는지 (converged)
        #  - planning: route가 SET/ARRIVED인데도 trajectory가 안 나오면 fault
        #    (route 미설정 상태에서 ntraj==0은 정상이므로 오탐 방지)
        #  - control: AD API(operation_mode) 응답 여부를 채널 생존 신호로 사용
        loc_fault  = not converged
        plan_fault = rstate in (2, 4) and ntraj == 0
        ctrl_fault = "op" not in s
        module_summary = {
            "localization": {"status": "OK" if not loc_fault  else "STALE", "hz": round(ndt_hz, 1)},
            "planning":     {"status": "OK" if not plan_fault else "STALE", "hz": float(ntraj)},
            "control":      {"status": "OK" if not ctrl_fault else "STALE", "hz": 0.0},
        }

        # 주행 모드 결정 — 모듈 장애가 센서 재구성보다 우선순위 높음
        if loc_fault and plan_fault:
            new_mode = "MRM"
        elif loc_fault or plan_fault or ctrl_fault:
            new_mode = "MODULE_FAULT"
        elif active == 0:
            new_mode = "GNSS_FALLBACK"
        elif active == 1:
            new_mode = "DEGRADED_1"
        elif active == 2:
            new_mode = "DEGRADED_2"
        elif active == 3:
            new_mode = "DEGRADED_3"
        else:
            new_mode = "NORMAL"

        # 부팅 직후(topic 미도착 구간)에는 STALE 오탐이 나기 쉬우므로, 측위가
        # 최초로 한 번 정상 수렴(converged)한 뒤부터만 모드 전환/이력을 기록한다.
        if not self._reconfig_settled:
            if converged and ntraj > 0:
                self._reconfig_settled = True
            else:
                new_mode = self._reconfig_mode  # 판정 보류, 이전 상태 유지

        # 모드 전환 감지
        if new_mode != self._reconfig_mode:
            faulty = [lid for lid in self._LIDARS_RCG
                      if inj.get(lid, {}).get("mode", "normal") != "normal"]
            ev = {"ts": _dt.datetime.now().strftime("%H:%M:%S"),
                  "from": self._reconfig_mode, "to": new_mode,
                  "faulty": faulty, "desc": self._MODE_DESC.get(new_mode, "")}
            self._reconfig_hist_deq.append(ev)
            self._reconfig_mode = new_mode

        return {
            "ts": _dt.datetime.now().strftime("%H:%M:%S"),
            "mode": new_mode,
            "mode_desc": self._MODE_DESC.get(new_mode, ""),
            "mode_level": self._MODE_PRI.get(new_mode, 0),
            "active_lidars": active,
            "sensors": sensor_summary,
            "modules": module_summary,
            "history": list(self._reconfig_hist_deq)[-5:],
        }

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
        # detected objects for the map. Prefer full-perception tracked objects
        # (PredictedObjects, already in map frame); fall back to CenterPoint
        # (DetectedObjects in base_link -> transform via the ego pose).
        objects = []
        if fresh("pobjs", 1.5):
            for ob in s["pobjs"][0].objects[:40]:
                p = ob.kinematics.initial_pose_with_covariance.pose
                oq = p.orientation
                oyaw = math.atan2(2 * (oq.w * oq.z + oq.x * oq.y),
                                  1 - 2 * (oq.y * oq.y + oq.z * oq.z))
                cls = (max(ob.classification, key=lambda c: c.probability).label
                       if ob.classification else 0)
                d = ob.shape.dimensions
                objects.append({"x": round(p.position.x, 1), "y": round(p.position.y, 1),
                                "yaw": round(math.degrees(oyaw)), "cls": int(cls),
                                "sx": round(max(d.x, 0.5), 1), "sy": round(max(d.y, 0.5), 1)})
        elif converged and fresh("objs", 1.0):
            ca, sa = math.cos(yaw), math.sin(yaw)
            for ob in s["objs"][0].objects[:40]:
                p = ob.kinematics.pose_with_covariance.pose
                lx, ly = p.position.x, p.position.y
                wx = ego["x"] + lx * ca - ly * sa
                wy = ego["y"] + lx * sa + ly * ca
                oq = p.orientation
                oyaw = math.atan2(2 * (oq.w * oq.z + oq.x * oq.y),
                                  1 - 2 * (oq.y * oq.y + oq.z * oq.z))
                cls = (max(ob.classification, key=lambda c: c.probability).label
                       if ob.classification else 0)
                d = ob.shape.dimensions
                objects.append({"x": round(wx, 1), "y": round(wy, 1),
                                "yaw": round(math.degrees(yaw + oyaw)),
                                "cls": int(cls),
                                "sx": round(max(d.x, 0.5), 1), "sy": round(max(d.y, 0.5), 1)})
        # traffic lights (AWSIM ground truth) -> world positions from the lanelet map.
        # Forward nearby lights for the 3D scene + pick the nearest one AHEAD of the ego
        # as the Tesla-style "upcoming signal" indicator. color: 1=RED 2=AMBER 3=GREEN.
        traffic_lights = []
        upcoming_tl = None
        # REAL light state from the traffic_light camera (matches the AWSIM sim exactly).
        # The camera only sees lights AHEAD, so we render the map lights in its forward FOV
        # with the detected colour and skip the ones it can't vouch for (also de-clutters).
        cam_color = self._cam_tl_color if (time.monotonic() - self._cam_tl_t < 2.0) else 0
        if converged and self.tl_points:
            ca, sa = math.cos(yaw), math.sin(yaw)
            # only the SINGLE nearest light ahead in the FOV matters (the one the car is
            # approaching) -> show just that one, coloured by the camera. Avoids clutter.
            best = None; best_fwd = 1e9
            for (gx, gy, gz) in self.tl_points:
                dx, dy = gx - ego["x"], gy - ego["y"]
                fwd = dx * ca + dy * sa
                rgt = -dx * sa + dy * ca
                if 3 < fwd < 70 and abs(rgt) < 16 and fwd < best_fwd:
                    best_fwd = fwd; best = (gx, gy, gz)
            if best is not None:
                gx, gy, gz = best
                traffic_lights.append({"x": round(gx, 1), "y": round(gy, 1),
                                       "z": round(gz, 1), "color": cam_color, "shape": 1})
                if cam_color:
                    upcoming_tl = {"color": cam_color, "dist": round(best_fwd)}
        # Realistic red-light behaviour: when autonomous and a RED is within stopping
        # range ahead, drop the external velocity limit to 0 (planner brakes smoothly);
        # otherwise restore cruise so the car proceeds (incl. on green). Pure stop-line
        # behaviour without touching the planning launch.
        if self.vlim_pub is not None:
            cur_mode = s["op"][0].mode if "op" in s else 0
            want = self.NORMAL_VLIM
            if cur_mode == 2 and upcoming_tl and upcoming_tl["color"] == 1 \
                    and upcoming_tl["dist"] <= 28:
                want = 0.0
            if want != self._vlim_now:
                self._vlim_now = want
                vl = self._VelocityLimit()
                vl.stamp = self.get_clock().now().to_msg()
                vl.max_velocity = float(want)
                vl.sender = "roii_gateway_tl"
                self.vlim_pub.publish(vl)
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
        if self._emergency:           # manual emergency stop overrides
            mrm = "EMERGENCY STOP"
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
        # Niro multimode telemetry (이중측위): live Pose Merger weights + sensors +
        # last transition event from niro_bridge (/niro/multimode/*).
        niro = None
        if "niro_status" in s and fresh("niro_status", 3):
            try:
                niro = json.loads(s["niro_status"][0].data)
                if "niro_event" in s and fresh("niro_event", 8):
                    niro["lastEvent"] = json.loads(s["niro_event"][0].data)
            except Exception:
                niro = None
        # live system monitor (실시간 노드/토픽 상태) -- node count cached ~4s
        nowt = time.time()
        if nowt - getattr(self, "_nodes_t", 0) > 4:
            try:
                self._nodes_cache = len(self.get_node_names())
            except Exception:
                self._nodes_cache = 0
            self._nodes_t = nowt
        system = {
            "nodes": getattr(self, "_nodes_cache", 0),
            "topics": [
                {"n": "localization", "ok": bool(converged), "v": f"{ndt_hz:.0f} Hz"},
                {"n": "planning", "ok": ntraj > 0, "v": f"{ntraj} pts"},
                {"n": "control", "ok": op == 2, "v": "AUTO" if op == 2 else "STOP"},
                {"n": "route", "ok": rstate in (2, 4), "v": ROUTE_STATE.get(rstate, "?")},
                {"n": "vehicle", "ok": fresh("steer"), "v": f"{steer_deg:.0f}°"},
            ],
        }
        # multimode (이중측위): LiDAR-only + GNSS-only ego positions and their gap
        def _pos(k):
            if k in s and (time.monotonic() - s[k][1] < 2.0):
                p = s[k][0].pose.pose.position
                return {"x": round(p.x, 2), "y": round(p.y, 2)}
            return None
        # LiDAR/"truth" position: dual lidar sub-EKF if present (Soongsil bag),
        # else the main fused pose (live ROii = NDT-driven).
        el = _pos("odom_lidar") or _pos("odom")
        gfault = getattr(self, "_gnss_fault", "normal")
        inj = _pos("odom_gnss_inj")
        if gfault != "normal":
            # a GNSS fault is active -> trust ONLY the injector output. 'drop' makes
            # it stale -> eg=None -> GNSS lost; drift/jump/noise -> gap grows.
            eg = inj
            sensors["gnss"] = "LOST" if eg is None else "FAULT"
        else:
            # normal: injector passthrough, else dual-EKF gnss (bag), else raw gnss (live)
            eg = inj or _pos("odom_gnss") or _pos("gnss_raw")
        gap = round(math.hypot(el["x"] - eg["x"], el["y"] - eg["y"]), 2) if (el and eg) else None
        multimode = {"lidar": el, "gnss": eg, "gapM": gap, "gnssFault": gfault,
                     "active": "LIDAR_GNSS" if (el and eg) else ("LIDAR" if el else ("GNSS" if eg else "NONE"))}
        return {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source": "AUTOWARE_LIVE",
            "site": MAP_ORIGIN,
            "multimode": multimode,
            "ego": ego,
            "niro": niro,
            "system": system,
            "localization": {"converged": converged and (loc_init == 3), "initState": loc_init,
                             "mode": (s["mmode"][0].data if "mmode" in s
                                      else ("LIDAR_GNSS" if lidar_ok else "UNAVAILABLE")),
                             "pipeline": "DUAL" if lidar_ok else "FALLBACK", "ndtHz": round(ndt_hz, 1)},
            "operationMode": {"mode": OP_MODE.get(op, "UNKNOWN"), "raw": op, "autonomousAvailable": op_avail},
            "route": {"state": ROUTE_STATE.get(rstate, "UNKNOWN"), "raw": rstate,
                      "trajPoints": ntraj, "trajPath": traj_path,
                      "routePath": (self.route_path if rstate in (2, 4) else [])},
            "vehicle": {"steerDeg": steer_deg, "turn": blink, "mrm": mrm,
                        "plannedKmh": planned_kmh},
            "roii": (json.loads(s["roii_health"][0].data)
                     if "roii_health" in s and fresh("roii_health", 3) else None),
            # 재구성 관리자: gateway 내장 계산 (injector status 기반)
            "reconfig": self._calc_reconfig(s, ndt_hz=ndt_hz, converged=converged,
                                            ntraj=ntraj, rstate=rstate, op_avail=op_avail),
            "faultReport": None,
            "objects": objects,
            "trafficLights": traffic_lights,
            "upcomingLight": upcoming_tl,
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
                elif cmd == "maxvel":
                    BRIDGE.enqueue(("maxvel", float(data.get("kmh", 40))))
                    print(f"[cmd] maxvel {data.get('kmh')}")
                elif cmd == "map":
                    # map switch needs a full re-launch (host side). Write a
                    # request file that scripts/map_switch_daemon.sh acts on.
                    # The gateway runs INSIDE the container whose /tmp is NOT
                    # shared with the host -- route the request through the
                    # autoware_map bind mount (/root/autoware_map <-> host
                    # /home/kim/autoware_map), which the daemon watches.
                    town = str(data.get("town", "Town04"))
                    # accept CARLA Towns AND real-map sites (pangyo_crd/pangyo_ngii/
                    # soongsil/kcity); the daemon routes real sites to planning_sim.
                    _real = ("pangyo", "soongsil", "kcity")
                    if town.replace("Town", "").replace("HD", "").isdigit() \
                       or any(town.startswith(s) for s in _real):
                        for p in ("/root/autoware_map/.roii_map_request",
                                  "/tmp/roii_map_request"):
                            try:
                                open(p, "w").write(town)
                            except OSError:
                                pass
                        BRIDGE.last_cmd_result = f"map switch -> {town} (재기동, ~3분)"
                        print(f"[cmd] map -> {town}")
                elif cmd == "fault":
                    import json as _json
                    payload = {k: v for k, v in data.items() if k != "cmd"}
                    BRIDGE.enqueue(("roii_fault", _json.dumps(payload)))
                    print(f"[cmd] roii fault {payload}")
                elif cmd == "gnss_fault":
                    import json as _json
                    payload = {k: v for k, v in data.items() if k != "cmd"}
                    BRIDGE.enqueue(("gnss_fault", _json.dumps(payload)))
                    print(f"[cmd] gnss fault {payload}")
                elif cmd == "trigger_emergency":
                    BRIDGE.enqueue("trigger_emergency")
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


async def camera_producer():
    # ship the latest front-camera JPEG to the tablet at ~6 Hz (separate from the
    # 2 Hz state frame so the surround/HUD stay responsive).
    last = 0.0
    while True:
        try:
            jpg = BRIDGE._jpg if BRIDGE else None
            if jpg and CLIENTS and BRIDGE._jpg_t != last:
                last = BRIDGE._jpg_t
                msg = json.dumps({"type": "camera", "jpg": jpg})
                await asyncio.gather(*[c.send(msg) for c in list(CLIENTS)], return_exceptions=True)
        except Exception as e:
            print("cam tick error:", e)
        await asyncio.sleep(0.16)


def spin_ros(bridge):
    ex = MultiThreadedExecutor(num_threads=4)
    ex.add_node(bridge)
    ex.spin()


async def main():
    global BRIDGE
    rclpy.init()
    BRIDGE = Bridge()
    threading.Thread(target=spin_ros, args=(BRIDGE,), daemon=True).start()
    # wall-clock command drain (immune to sim-time ROS-timer freeze on planning_sim)
    threading.Thread(target=BRIDGE.cmd_loop, daemon=True).start()
    print("=" * 56)
    print("Autoware ROS <-> ROii Monitor gateway (with drive control)")
    print(f"  ws://<host>:{WS_PORT}{WS_PATH}   (USB: adb reverse tcp:{WS_PORT} tcp:{WS_PORT})")
    print("=" * 56)
    # ping_interval keeps tablet links alive and reaps half-open/stale connections
    # (prevents ESTAB pile-up); close_timeout bounds shutdown of dropped clients.
    async with websockets.serve(handler, WS_HOST, WS_PORT,
                                ping_interval=20, ping_timeout=20, close_timeout=5):
        await asyncio.gather(producer(), camera_producer())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
