#!/usr/bin/env python3
"""LiDAR Fault Adapter (문서 'Lidar Virtual Driver').

Bridges the reconfigurable E/E architecture's LiDAR fault state into a normalized
Autoware fault signal that the Pose Merger / Mode Manager consume. Also accepts a
manual test injection.

Inputs:
    /adaptation/ee/lidar_status   (std_msgs/String, JSON from the E/E layer:
                                   {fault, severity, reason, source, sensor_id})
    /test/fault_injection/lidar   (std_msgs/Bool, manual test)
    (passive) the actual LiDAR cloud rate can also flag a fault if it stalls.

Outputs:
    /adaptation/lidar_fault         (std_msgs/Bool)
    /adaptation/lidar_fault_status  (std_msgs/String, JSON:
        timestamp, sensor_id, fault, severity, reason, source)
"""
import json
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_msgs.msg import String, Bool
from sensor_msgs.msg import PointCloud2


class LidarFaultAdapter(Node):
    def __init__(self):
        super().__init__("niro_lidar_fault_adapter")
        self.sensor_id = self.declare_parameter("sensor_id", "ouster_os2_top").value
        self.cloud_stale_sec = self.declare_parameter("cloud_stale_sec", 0.5).value
        self.cloud_topic = self.declare_parameter(
            "cloud_topic", "/sensing/lidar/top/pointcloud_raw").value

        self._ee = None         # latest E/E status dict
        self._inject = False    # manual test injection
        self._cloud_t = 0.0

        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(String, "/adaptation/ee/lidar_status", self._cb_ee, be)
        self.create_subscription(Bool, "/test/fault_injection/lidar",
                                 lambda m: setattr(self, "_inject", m.data), 1)
        bel = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(PointCloud2, self.cloud_topic,
                                 lambda m: setattr(self, "_cloud_t", self._now()), bel)

        self.pub_fault = self.create_publisher(Bool, "/adaptation/lidar_fault", be)
        self.pub_status = self.create_publisher(String, "/adaptation/lidar_fault_status", be)
        self.create_timer(0.1, self._tick)  # 10 Hz
        self.get_logger().info(f"LiDAR Fault Adapter up (sensor={self.sensor_id})")

    def _now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def _cb_ee(self, m):
        try:
            self._ee = json.loads(m.data)
        except Exception:
            self._ee = {"fault": True, "severity": "unknown", "reason": "bad_ee_msg"}

    def _tick(self):
        fault, severity, reason, source = False, "none", "", "none"
        # 1) E/E adaptation layer (authoritative)
        if self._ee is not None:
            fault = bool(self._ee.get("fault", False))
            severity = self._ee.get("severity", "high" if fault else "none")
            reason = self._ee.get("reason", "ee_layer")
            source = self._ee.get("source", "ee_adaptation")
        # 2) manual test injection
        if self._inject:
            fault, severity, reason, source = True, "high", "manual_injection", "test"
        # 3) passive: LiDAR cloud stalled (data-link / sensor dead)
        if self._cloud_t > 0 and (self._now() - self._cloud_t) > self.cloud_stale_sec:
            fault, severity = True, max(severity, "high")
            reason = reason or "cloud_stale"; source = source if fault else "rate_monitor"

        self.pub_fault.publish(Bool(data=fault))
        self.pub_status.publish(String(data=json.dumps({
            "timestamp": self._now(), "sensor_id": self.sensor_id,
            "fault": fault, "severity": severity, "reason": reason, "source": source})))


def main():
    rclpy.init()
    n = LidarFaultAdapter()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
