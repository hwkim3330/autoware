#!/usr/bin/env python3
"""
ROS -> WebSocket gateway for the ROii Autoware Monitor tablet app.

Unlike ros/carla_ws_gateway.py (which reads CARLA directly and therefore sees
nothing while the autoware_carla_interface holds CARLA in synchronous mode), this
gateway subscribes to the LIVE Autoware ROS graph and streams the real autonomous
state: NDT localization, operation mode, route state, control command, ego speed.

Run INSIDE the Autoware container (it needs rclpy + the running graph):
    docker exec -d autoware bash -lc \
      "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; \
       python3 /root/ros_ws_gateway.py"

Tablet connects via:
    Wi-Fi : ws://<host-ip>:8765/ws
    USB   : adb reverse tcp:8765 tcp:8765  ->  ws://127.0.0.1:8765/ws

Frame contract (consumed by the Flutter app's WebSocketMonitorService):
{
  "ts": <iso>,
  "ego":        {"x":, "y":, "z":, "yawDeg":, "speedKmh":},
  "localization":{"converged":bool, "mode":str, "pipeline":str, "ndtHz":float},
  "operationMode":{"mode":"AUTONOMOUS|STOP|...", "autonomousAvailable":bool},
  "route":      {"state":"UNSET|SET|ARRIVED", "stateText":str},
  "control":    {"throttle":, "steeringDeg":, "speedCmdKmh":},
  "sensors":    {"lidar":"OK|FAULT|OFF", "gnss":..., "imu":..., "camera":"OFF"},
  "faults":     [<glb material name>, ...]   # parts to highlight red on the 3D model
}
"""
import asyncio, json, math, time, threading, datetime

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy, HistoryPolicy
import websockets

from nav_msgs.msg import Odometry
from autoware_adapi_v1_msgs.msg import (
    OperationModeState, RouteState, LocalizationInitializationState,
)

WS_HOST, WS_PORT, WS_PATH = "0.0.0.0", 8765, "/ws"

# Map a faulted sensor to the roii.glb material names (see app constants.dart).
SENSOR_PARTS = {
    "lidar":  ["FrontLeftLidar", "FrontRightLidar", "FrontCenterLidar", "RearCenterLidar"],
    "camera": ["FrontCenterCamera", "FrontLeftCamera", "FrontRightCamera",
               "RearCenterCamera", "SideLeft1Camera", "SideRight1Camera"],
    "gnss":   ["VCU"],   # no gnss mesh; flag the compute unit instead
}
OP_MODE = {0: "UNKNOWN", 1: "STOP", 2: "AUTONOMOUS", 3: "LOCAL", 4: "REMOTE"}
ROUTE_STATE = {0: "UNKNOWN", 1: "UNSET", 2: "SET", 3: "ARRIVED", 4: "CHANGING"}


class Bridge(Node):
    def __init__(self):
        super().__init__("roii_ws_gateway")
        self.lock = threading.Lock()
        self.s = {}            # latest messages by key
        self.lidar_t = []      # timestamps for hz estimate

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
        # lidar liveness (best_effort sensor QoS)
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        from sensor_msgs.msg import PointCloud2
        self.create_subscription(PointCloud2, "/localization/util/downsample/pointcloud",
                                 self._lidar_tick, be)

    def _set(self, k, m):
        with self.lock:
            self.s[k] = (m, time.monotonic())

    def _lidar_tick(self, _m):
        now = time.monotonic()
        with self.lock:
            self.lidar_t.append(now)
            self.lidar_t = [t for t in self.lidar_t if now - t < 3.0]

    def frame(self):
        with self.lock:
            s = dict(self.s)
            lt = list(self.lidar_t)
        now = time.monotonic()

        def fresh(key, age=2.0):
            v = s.get(key)
            return v and (now - v[1]) < age

        ndt_hz = 0.0
        if len(lt) >= 2:
            ndt_hz = (len(lt) - 1) / max(1e-3, (lt[-1] - lt[0]))
        lidar_ok = ndt_hz > 1.0

        ego = {"x": 0, "y": 0, "z": 0, "yawDeg": 0, "speedKmh": 0}
        converged = False
        if fresh("odom"):
            o = s["odom"][0].pose.pose
            q = o.orientation
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

        # sensor health -> faults (lidar-only kit: gnss/imu present, camera off)
        sensors = {
            "lidar": "OK" if lidar_ok else "FAULT",
            "gnss": "OK", "imu": "OK", "camera": "OFF",
        }
        faults = [] if lidar_ok else SENSOR_PARTS["lidar"]
        mode = "LIDAR_GNSS" if lidar_ok else "UNAVAILABLE"

        return {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source": "AUTOWARE_LIVE",
            "ego": ego,
            "localization": {"converged": converged and (loc_init == 3),
                             "initState": loc_init, "mode": mode,
                             "pipeline": "DUAL" if lidar_ok else "UNAVAILABLE",
                             "ndtHz": round(ndt_hz, 1)},
            "operationMode": {"mode": OP_MODE.get(op, "UNKNOWN"), "raw": op,
                              "autonomousAvailable": op_avail},
            "route": {"state": ROUTE_STATE.get(rstate, "UNKNOWN"), "raw": rstate},
            "sensors": sensors,
            "faults": faults,
        }


CLIENTS = set()


async def handler(ws):
    CLIENTS.add(ws)
    print(f"[+] app connected ({len(CLIENTS)})")
    try:
        await ws.wait_closed()
    finally:
        CLIENTS.discard(ws)
        print(f"[-] app disconnected ({len(CLIENTS)})")


async def producer(bridge):
    while True:
        try:
            payload = json.dumps(bridge.frame())
            if CLIENTS:
                await asyncio.gather(*[c.send(payload) for c in list(CLIENTS)],
                                     return_exceptions=True)
        except Exception as e:
            print("tick error:", e)
        await asyncio.sleep(0.5)


def spin_ros(bridge):
    rclpy.spin(bridge)


async def main():
    rclpy.init()
    bridge = Bridge()
    threading.Thread(target=spin_ros, args=(bridge,), daemon=True).start()
    print("=" * 56)
    print("Autoware ROS -> ROii Monitor  WebSocket gateway")
    print(f"  Wi-Fi : ws://<host-ip>:{WS_PORT}{WS_PATH}")
    print(f"  USB   : adb reverse tcp:{WS_PORT} tcp:{WS_PORT}  ->  ws://127.0.0.1:{WS_PORT}{WS_PATH}")
    print("=" * 56)
    async with websockets.serve(handler, WS_HOST, WS_PORT):
        await producer(bridge)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
