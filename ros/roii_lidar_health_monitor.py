#!/usr/bin/env python3
"""ROii LiDAR health monitor.

Watches the four POST-injector clouds and publishes:
  /diagnostics            diagnostic_msgs/DiagnosticArray (per-sensor + aggregate)
  /roii/lidar_health      std_msgs/String JSON (consumed by the RViz panel + app)

Per-sensor checks:
  timeout            no cloud for > 1.0 s              -> STALE/ERROR
  hz                 < 5 Hz WARN, < 2 Hz ERROR
  timestamp invalid  |now - header.stamp| > 0.5 s      -> ERROR
  TF missing         base_link <- frame lookup fails   -> ERROR
  point count low    below per-profile minimum         -> WARN

Aggregate policy:
  front_g32 faulty            -> ERROR
  rear_g32 faulty             -> WARN
  one side pandar faulty      -> DEGRADED (WARN)
  both side pandars faulty    -> ERROR
  >= 2 lidars faulty          -> ERROR
"""
import json
import os
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2
from std_msgs.msg import String
from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus, KeyValue

import tf2_ros

SENSORS = {
    "front_g32": "roii_front_g32",
    "rear_g32": "roii_rear_g32",
    "left_pandar": "roii_left_pandar",
    "right_pandar": "roii_right_pandar",
}
MIN_POINTS = int(os.environ.get("ROII_MIN_POINTS", "1000"))  # per-profile floor
LEVEL = {"OK": DiagnosticStatus.OK, "WARN": DiagnosticStatus.WARN,
         "DEGRADED": DiagnosticStatus.WARN, "ERROR": DiagnosticStatus.ERROR,
         "STALE": DiagnosticStatus.STALE}


class Monitor(Node):
    def __init__(self):
        super().__init__("roii_lidar_health_monitor")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.tf_buffer = tf2_ros.Buffer()
        self.tf_listener = tf2_ros.TransformListener(self.tf_buffer, self)
        self.s = {k: {"times": [], "stamp_diff": 0.0, "points": 0, "tf": False}
                  for k in SENSORS}
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        for name in SENSORS:
            self.create_subscription(
                PointCloud2, f"/sensing/lidar/{name}/pointcloud_before_sync",
                (lambda n: lambda m: self._on_cloud(n, m))(name), be)
        self.pub_diag = self.create_publisher(DiagnosticArray, "/diagnostics", 5)
        self.pub_health = self.create_publisher(String, "/roii/lidar_health", 1)
        self.create_timer(1.0, self._tick)
        self.get_logger().info("ROii lidar health monitor up (4 sensors)")

    def _on_cloud(self, name, m):
        now_w = time.monotonic()
        st = self.s[name]
        st["times"].append(now_w)
        st["times"] = [t for t in st["times"] if now_w - t < 3.0]
        st["points"] = m.width * max(1, m.height)
        now_ros = self.get_clock().now().nanoseconds * 1e-9
        stamp = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        st["stamp_diff"] = abs(now_ros - stamp)

    def _eval(self, name):
        st = self.s[name]
        now_w = time.monotonic()
        times = st["times"]
        info = {"hz": 0.0, "stamp_diff": round(st["stamp_diff"], 3),
                "points": st["points"], "tf": False, "status": "OK", "reasons": []}
        # TF
        try:
            self.tf_buffer.lookup_transform("base_link", SENSORS[name],
                                            rclpy.time.Time())
            info["tf"] = True
        except Exception:
            info["reasons"].append("tf_missing")
        # timeout / hz
        if not times or now_w - times[-1] > 1.0:
            info["status"] = "STALE"
            info["reasons"].append("timeout")
        else:
            if len(times) >= 2:
                info["hz"] = round((len(times) - 1) / max(1e-3, times[-1] - times[0]), 1)
            if info["hz"] < 2.0:
                info["status"] = "ERROR"; info["reasons"].append("hz<2")
            elif info["hz"] < 5.0:
                info["status"] = "WARN"; info["reasons"].append("hz<5")
            if st["stamp_diff"] > 0.5:
                info["status"] = "ERROR"; info["reasons"].append("stamp_invalid")
            if st["points"] < MIN_POINTS:
                if info["status"] == "OK":
                    info["status"] = "WARN"
                info["reasons"].append("low_points")
        if not info["tf"] and info["status"] != "STALE":
            info["status"] = "ERROR"
        return info

    def _tick(self):
        per = {n: self._eval(n) for n in SENSORS}
        # aggregate policy
        bad = {n: per[n]["status"] in ("ERROR", "STALE") for n in SENSORS}
        warn = {n: per[n]["status"] == "WARN" for n in SENSORS}
        agg = "OK"
        if sum(bad.values()) >= 2:
            agg = "ERROR"
        elif bad["front_g32"]:
            agg = "ERROR"
        elif bad["left_pandar"] and bad["right_pandar"]:
            agg = "ERROR"
        elif bad["rear_g32"] or bad["left_pandar"] or bad["right_pandar"]:
            agg = "DEGRADED"
        elif any(warn.values()):
            agg = "WARN"
        # /roii/lidar_health JSON
        health = {"aggregate": agg, "sensors": per,
                  "ts": self.get_clock().now().nanoseconds * 1e-9}
        self.pub_health.publish(String(data=json.dumps(health)))
        # /diagnostics
        da = DiagnosticArray()
        da.header.stamp = self.get_clock().now().to_msg()
        for n, info in per.items():
            ds = DiagnosticStatus()
            ds.name = f"roii_lidar: {n}"
            ds.hardware_id = SENSORS[n]
            ds.level = LEVEL[info["status"]]
            ds.message = info["status"] + (
                f" ({','.join(info['reasons'])})" if info["reasons"] else "")
            ds.values = [KeyValue(key=k, value=str(v))
                         for k, v in info.items() if k != "reasons"]
            da.status.append(ds)
        ag = DiagnosticStatus()
        ag.name = "roii_lidar: aggregate"
        ag.hardware_id = "roii_lidar_suite"
        ag.level = LEVEL["WARN" if agg == "DEGRADED" else agg]
        ag.message = agg
        da.status.append(ag)
        self.pub_diag.publish(da)


def main():
    rclpy.init()
    rclpy.spin(Monitor())


if __name__ == "__main__":
    main()
