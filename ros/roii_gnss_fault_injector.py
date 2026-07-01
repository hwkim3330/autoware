#!/usr/bin/env python3
"""ROii GNSS fault injector (mirror of roii_lidar_fault_injector for GNSS).

The ROii/Soongsil multimode stack drives on LiDAR NDT; GNSS is the comparison
source the tablet uses to show the LiDAR<->GNSS gap. This node sits on the live
GNSS pose stream:

    /sensing/gnss/pose_with_covariance   (gnss_poser, map frame, ~12 Hz)
        -> [fault model] ->
    /roii/gnss/pose_with_covariance      (gateway reads this for the gap)

so a GNSS fault visibly grows the gap / flips GNSS to FAULT on the tablet while
the car keeps driving on LiDAR (localization untouched -> safe, no relaunch).
(The dual gnss/lidar sub-EKF topics only exist in the Soongsil bag, not live;
the raw gnss pose is the live-and-bag common source.)

Fault modes (optional duration, then revert to normal):
    normal        pass through unchanged
    drop          publish nothing (GNSS goes stale -> gateway marks it LOST)
    drift         add an accumulating offset at drift_mps m/s (default 0.5)
    jump          add a fixed jump_m offset (default 8.0 m)
    noise         add uniform +/- noise_m jitter each msg (default 3.0 m)
    freeze        keep republishing the last good pose (stale-but-alive)

Command topic (std_msgs/String, JSON): /roii/gnss_fault/command
    {"mode":"drift","drift_mps":0.5,"duration":15.0}
    {"mode":"jump","jump_m":10.0}   {"mode":"drop","duration":10.0}   {"mode":"normal"}
Status (std_msgs/String, JSON): /roii/gnss_fault/status  (1 Hz)
"""
import json
import random
import threading
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from geometry_msgs.msg import PoseWithCovarianceStamped
from std_msgs.msg import String

SRC = "/sensing/gnss/pose_with_covariance"
OUT = "/roii/gnss/pose_with_covariance"


class GnssInjector(Node):
    def __init__(self):
        super().__init__("roii_gnss_fault_injector")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.lock = threading.Lock()
        self.state = {"mode": "normal", "until": None, "params": {},
                      "frozen": None, "t0": None}
        rel = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                         history=HistoryPolicy.KEEP_LAST)
        self.pub = self.create_publisher(PoseWithCovarianceStamped, OUT, rel)
        self.create_subscription(PoseWithCovarianceStamped, SRC, self._on_pose, rel)
        self.create_subscription(String, "/roii/gnss_fault/command", self._on_cmd, 10)
        self.pub_status = self.create_publisher(String, "/roii/gnss_fault/status", 1)
        self.create_timer(1.0, self._status_tick)
        self.get_logger().info(f"ROii GNSS fault injector up: {SRC} -> {OUT}")

    def _on_cmd(self, msg):
        try:
            cmd = json.loads(msg.data)
        except Exception as e:
            self.get_logger().warn(f"bad command json: {e}")
            return
        mode = cmd.get("mode", "normal")
        dur = cmd.get("duration")
        until = (time.monotonic() + float(dur)) if dur else None
        with self.lock:
            self.state = {"mode": mode, "until": until, "params": cmd,
                          "frozen": None, "t0": time.monotonic()}
        self.get_logger().warn(f"GNSS FAULT -> {mode}" + (f" for {dur}s" if dur else ""))

    def _mode_now(self):
        with self.lock:
            st = self.state
            if st["until"] is not None and time.monotonic() > st["until"]:
                self.state = {"mode": "normal", "until": None, "params": {},
                              "frozen": None, "t0": None}
            return dict(self.state)

    def _on_pose(self, m):
        st = self._mode_now()
        mode, p, t0 = st["mode"], st["params"], st["t0"]
        if mode == "normal":
            self.pub.publish(m)
        elif mode == "drop":
            return
        elif mode == "freeze":
            with self.lock:
                if self.state["frozen"] is None:
                    self.state["frozen"] = m
                frozen = self.state["frozen"]
            self.pub.publish(frozen)
        elif mode in ("drift", "jump", "noise"):
            if mode == "drift":
                dx = dy = float(p.get("drift_mps", 0.5)) * (time.monotonic() - (t0 or time.monotonic()))
            elif mode == "jump":
                dx = dy = float(p.get("jump_m", 8.0))
            else:  # noise
                n = float(p.get("noise_m", 3.0))
                dx = random.uniform(-n, n); dy = random.uniform(-n, n)
            m.pose.pose.position.x += dx
            m.pose.pose.position.y += dy
            self.pub.publish(m)
        else:
            self.pub.publish(m)

    def _status_tick(self):
        with self.lock:
            st = self.state
            rem = round(st["until"] - time.monotonic(), 1) if st["until"] else None
        self.pub_status.publish(String(data=json.dumps({"mode": st["mode"], "remaining": rem})))


def main():
    rclpy.init()
    rclpy.spin(GnssInjector())


if __name__ == "__main__":
    main()
