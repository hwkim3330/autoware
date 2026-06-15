#!/usr/bin/env python3
"""ROii stack watchdog — keeps the demo error-free without touching Autoware.

Runs inside the container (started by the bring-up). Every few seconds it
checks the two components that have historically failed silently and auto-heals
them, so the user never lands in a "looks up but won't drive / won't connect"
state:

  1. perception_stub — if /perception/object_recognition/objects goes stale,
     the perception rate-check diagnostics turn ERROR and AUTONOMOUS refuses to
     engage. Watchdog restarts the stub.
  2. ros_ws_gateway — if the websocket port 8765 is not bound (zombie gateway),
     the tablet/app silently can't connect. Watchdog restarts the gateway.

It also reports ego sensor liveness on /roii/watchdog (JSON): when odometry goes
stale the ego vehicle is effectively gone (despawn) — that needs a full
re-launch, which the watchdog flags clearly rather than leaving things hung.

Env (inherited from the bring-up): LANELET_OSM, CARLA_SPAWN, RVIZ_DISPLAY.
"""
import json
import os
import socket
import subprocess
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_msgs.msg import String
from nav_msgs.msg import Odometry
from autoware_perception_msgs.msg import PredictedObjects

SETUP = "source /opt/autoware/setup.bash"
ENVX = "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml"


def sh(cmd):
    subprocess.Popen(["bash", "-lc", cmd], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Watchdog(Node):
    def __init__(self):
        super().__init__("roii_watchdog")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.t_obj = 0.0
        self.t_odom = 0.0
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(PredictedObjects, "/perception/object_recognition/objects",
                                 lambda m: setattr(self, "t_obj", time.monotonic()), 1)
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 lambda m: setattr(self, "t_odom", time.monotonic()), be)
        self.pub = self.create_publisher(String, "/roii/watchdog", 1)
        self.lanelet = os.environ.get("LANELET_OSM", "/root/autoware_map/Town04/lanelet2_map.osm")
        self.spawn = os.environ.get("CARLA_SPAWN", "")
        self.disp = os.environ.get("RVIZ_DISPLAY", ":1")
        self._obj_grace = time.monotonic() + 30   # let things come up first
        self._gw_grace = time.monotonic() + 30
        self.create_timer(5.0, self._tick)
        self.get_logger().info("ROii watchdog up (perception_stub + gateway auto-heal)")

    def _port_open(self, port):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        try:
            return s.connect_ex(("127.0.0.1", port)) == 0
        finally:
            s.close()

    def _restart_stub(self):
        self.get_logger().warn("perception objects STALE -> restarting perception_stub")
        sh("pkill -9 -f perception_stub.py; sleep 1; " + ENVX + "; " + SETUP +
           "; python3 -u /root/perception_stub.py --ros-args -p use_sim_time:=true > /tmp/pstub.log 2>&1")
        self._obj_grace = time.monotonic() + 20

    def _restart_gateway(self):
        self.get_logger().warn("gateway port 8765 down -> restarting ros_ws_gateway")
        sh("pkill -9 -f ros_ws_gateway.py; sleep 1; " + ENVX +
           f"; export LANELET_OSM={self.lanelet}; export CARLA_SPAWN='{self.spawn}'; export RVIZ_DISPLAY={self.disp}; "
           + SETUP +
           "; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1")
        self._gw_grace = time.monotonic() + 25

    def _tick(self):
        now = time.monotonic()
        obj_ok = (now - self.t_obj) < 6.0 if self.t_obj else False
        odom_ok = (now - self.t_odom) < 4.0 if self.t_odom else False
        if now > self._obj_grace and not obj_ok:
            self._restart_stub()
        if now > self._gw_grace and not self._port_open(8765):
            self._restart_gateway()
        self.pub.publish(String(data=json.dumps({
            "perception": "OK" if obj_ok else "STALE",
            "gateway": "OK" if self._port_open(8765) else "DOWN",
            "ego": "OK" if odom_ok else "LOST (re-launch ./run.sh)",
        })))


def main():
    rclpy.init()
    rclpy.spin(Watchdog())


if __name__ == "__main__":
    main()
