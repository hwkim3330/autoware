#!/usr/bin/env python3
"""ROii LiDAR fault injector.

Sits between the CARLA interface and the concatenation:
    /sensing/lidar/<name>/pointcloud_raw   (interface output)
        -> [fault model] ->
    /sensing/lidar/<name>/pointcloud_before_sync   (concat input)

Sensors: front_g32, rear_g32, left_pandar, right_pandar.

Fault modes (per sensor, optional duration after which it reverts to normal):
    normal        pass through unchanged
    drop          publish nothing
    delay         republish after delay_ms (default 500)
    downsample    keep `ratio` of points (default 0.1)
    stamp_zero    header.stamp = 0
    stamp_offset  header.stamp += offset_sec (default -5.0)
    freeze        keep republishing the last frozen cloud (stale data)

Command topic (std_msgs/String, JSON):
    /roii/fault_injector/command
    {"sensor":"front_g32","mode":"drop","duration":10.0}
    {"sensor":"left_pandar","mode":"stamp_offset","offset_sec":-5.0,"duration":10.0}
    {"sensor":"all","mode":"normal"}

Status (std_msgs/String, JSON): /roii/fault_injector/status  (1 Hz)
"""
import json
import threading
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2
from std_msgs.msg import String

SENSORS = ("front_g32", "rear_g32", "left_pandar", "right_pandar")


class Injector(Node):
    def __init__(self):
        super().__init__("roii_lidar_fault_injector")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.lock = threading.Lock()
        # per-sensor fault state
        self.state = {s: {"mode": "normal", "until": None, "params": {}, "frozen": None}
                      for s in SENSORS}
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        self.pubs = {}
        for s in SENSORS:
            self.pubs[s] = self.create_publisher(
                PointCloud2, f"/sensing/lidar/{s}/pointcloud_before_sync", be)
            self.create_subscription(
                PointCloud2, f"/sensing/lidar/{s}/pointcloud_raw",
                (lambda name: lambda m: self._on_cloud(name, m))(s), be)
        self.create_subscription(String, "/roii/fault_injector/command", self._on_cmd, 10)
        self.pub_status = self.create_publisher(String, "/roii/fault_injector/status", 1)
        self.create_timer(1.0, self._status_tick)
        self.get_logger().info("ROii fault injector up: raw -> before_sync (4 lidars)")

    # ---- command handling -------------------------------------------------
    def _on_cmd(self, msg):
        try:
            cmd = json.loads(msg.data)
        except Exception as e:
            self.get_logger().warn(f"bad command json: {e}")
            return
        sensors = SENSORS if cmd.get("sensor") == "all" else [cmd.get("sensor")]
        mode = cmd.get("mode", "normal")
        dur = cmd.get("duration")
        until = (time.monotonic() + float(dur)) if dur else None
        with self.lock:
            for s in sensors:
                if s not in self.state:
                    self.get_logger().warn(f"unknown sensor '{s}'")
                    continue
                self.state[s] = {"mode": mode, "until": until,
                                 "params": cmd, "frozen": None}
        self.get_logger().warn(f"FAULT {sensors} -> {mode}"
                               + (f" for {dur}s" if dur else ""))

    def _mode_of(self, s):
        with self.lock:
            st = self.state[s]
            if st["until"] is not None and time.monotonic() > st["until"]:
                st["mode"], st["until"], st["frozen"] = "normal", None, None
            return dict(st)

    # ---- data path ---------------------------------------------------------
    def _on_cloud(self, s, m):
        st = self._mode_of(s)
        mode, p = st["mode"], st["params"]
        if mode == "normal":
            self.pubs[s].publish(m)
        elif mode == "drop":
            return
        elif mode == "delay":
            delay = float(p.get("delay_ms", 500)) / 1000.0
            threading.Timer(delay, lambda: self.pubs[s].publish(m)).start()
        elif mode == "downsample":
            ratio = max(0.001, min(1.0, float(p.get("ratio", 0.1))))
            step = max(1, int(round(1.0 / ratio)))
            out = PointCloud2()
            out.header = m.header
            out.height = 1
            out.fields = m.fields
            out.is_bigendian = m.is_bigendian
            out.point_step = m.point_step
            out.is_dense = m.is_dense
            data = bytes(m.data)
            n = len(data) // m.point_step
            kept = b"".join(data[i * m.point_step:(i + 1) * m.point_step]
                            for i in range(0, n, step))
            out.width = len(kept) // m.point_step
            out.row_step = len(kept)
            out.data = kept
            self.pubs[s].publish(out)
        elif mode == "stamp_zero":
            m.header.stamp.sec = 0
            m.header.stamp.nanosec = 0
            self.pubs[s].publish(m)
        elif mode == "stamp_offset":
            off = float(p.get("offset_sec", -5.0))
            t = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9 + off
            m.header.stamp.sec = max(0, int(t))
            m.header.stamp.nanosec = max(0, int((t - int(t)) * 1e9))
            self.pubs[s].publish(m)
        elif mode == "freeze":
            with self.lock:
                if self.state[s]["frozen"] is None:
                    self.state[s]["frozen"] = m
                frozen = self.state[s]["frozen"]
            self.pubs[s].publish(frozen)
        else:
            self.pubs[s].publish(m)

    def _status_tick(self):
        with self.lock:
            st = {s: {"mode": v["mode"],
                      "remaining": (round(v["until"] - time.monotonic(), 1)
                                    if v["until"] else None)}
                  for s, v in self.state.items()}
        self.pub_status.publish(String(data=json.dumps(st)))


def main():
    rclpy.init()
    rclpy.spin(Injector())


if __name__ == "__main__":
    main()
