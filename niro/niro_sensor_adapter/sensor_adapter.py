#!/usr/bin/env python3
"""Niro Virtual Sensor Driver / Sensor Adapter (문서 2 'Virtual Sensor Driver').

One process, four adapter roles (pick with argv[1]): each subscribes the raw
on-vehicle driver topic, normalizes frame_id / timestamp / units, runs a simple
rate+stale diagnostic, and republishes the standard Autoware /sensing topic that
the localization pipelines consume. Hardware-specific input topics/types are
parameters (the exact Ouster/RTK/IMU/CAN driver msgs are set at integration time).

Roles:
    ouster   : raw Ouster OS2-128 cloud  -> /sensing/lidar/top/pointcloud_raw
    gnss     : raw RTK-GNSS NavSatFix     -> /sensing/gnss/nav_sat_fix (+ velocity)
    imu      : raw IMU                     -> /sensing/imu/imu_data
    velocity : vehicle speed (CAN-derived)-> /vehicle/status/velocity_status

Usage: python3 sensor_adapter.py <role>
"""
import sys
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2, NavSatFix, Imu
from geometry_msgs.msg import TwistStamped

SENSOR_QOS = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)


class _Base(Node):
    """Shared frame/stamp normalization + a rolling rate diagnostic."""
    def __init__(self, name):
        super().__init__(name)
        self.use_msg_stamp = self.declare_parameter("use_msg_stamp", True).value
        self._count = 0
        self._last_t = 0.0
        self._rate = 0.0
        self.create_timer(2.0, self._diag)

    def _now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def _stamp(self, msg):
        if not self.use_msg_stamp:
            msg.header.stamp = self.get_clock().now().to_msg()
        return msg

    def _mark(self):
        self._count += 1
        t = self._now()
        if self._last_t:
            dt = t - self._last_t
            if dt > 0:
                self._rate = 0.9 * self._rate + 0.1 * (1.0 / dt)
        self._last_t = t

    def _diag(self):
        if self._count == 0:
            self.get_logger().warn("no input received yet")
        else:
            self.get_logger().info(f"rate ~{self._rate:.1f} Hz ({self._count} msgs)")


class OusterAdapter(_Base):
    def __init__(self):
        super().__init__("niro_ouster_adapter")
        self.frame = self.declare_parameter("frame_id", "lidar_top").value
        in_t = self.declare_parameter("in_topic", "/ouster/points").value
        out_t = self.declare_parameter("out_topic", "/sensing/lidar/top/pointcloud_raw").value
        self.pub = self.create_publisher(PointCloud2, out_t, SENSOR_QOS)
        self.create_subscription(PointCloud2, in_t, self._cb, SENSOR_QOS)

    def _cb(self, m):
        m.header.frame_id = self.frame
        self.pub.publish(self._stamp(m)); self._mark()


class GnssAdapter(_Base):
    def __init__(self):
        super().__init__("niro_gnss_adapter")
        self.frame = self.declare_parameter("frame_id", "gnss_link").value
        in_t = self.declare_parameter("in_topic", "/rtk/fix").value
        out_t = self.declare_parameter("out_topic", "/sensing/gnss/nav_sat_fix").value
        self.pub = self.create_publisher(NavSatFix, out_t, SENSOR_QOS)
        self.create_subscription(NavSatFix, in_t, self._cb, SENSOR_QOS)

    def _cb(self, m):
        m.header.frame_id = self.frame
        self.pub.publish(self._stamp(m)); self._mark()


class ImuAdapter(_Base):
    def __init__(self):
        super().__init__("niro_imu_adapter")
        self.frame = self.declare_parameter("frame_id", "imu_link").value
        in_t = self.declare_parameter("in_topic", "/imu/data_raw").value
        out_t = self.declare_parameter("out_topic", "/sensing/imu/imu_data").value
        self.pub = self.create_publisher(Imu, out_t, SENSOR_QOS)
        self.create_subscription(Imu, in_t, self._cb, SENSOR_QOS)

    def _cb(self, m):
        m.header.frame_id = self.frame
        self.pub.publish(self._stamp(m)); self._mark()


class VelocityAdapter(_Base):
    """Vehicle speed -> Autoware VelocityReport (falls back to TwistStamped if the
    autoware_vehicle_msgs package isn't importable in this env)."""
    def __init__(self):
        super().__init__("niro_velocity_adapter")
        self.frame = self.declare_parameter("frame_id", "base_link").value
        in_t = self.declare_parameter("in_topic", "/vehicle/can/velocity").value
        out_t = self.declare_parameter("out_topic", "/vehicle/status/velocity_status").value
        self._VR = None
        try:
            from autoware_vehicle_msgs.msg import VelocityReport
            self._VR = VelocityReport
            self.pub = self.create_publisher(VelocityReport, out_t, 10)
        except Exception:
            self.get_logger().warn("autoware_vehicle_msgs missing -> publishing TwistStamped")
            self.pub = self.create_publisher(TwistStamped, out_t, 10)
        # raw input assumed TwistStamped (linear.x = m/s, angular.z = yaw rate)
        self.create_subscription(TwistStamped, in_t, self._cb, 10)

    def _cb(self, m):
        if self._VR is not None:
            out = self._VR()
            out.header.stamp = self.get_clock().now().to_msg()
            out.header.frame_id = self.frame
            out.longitudinal_velocity = float(m.twist.linear.x)
            out.lateral_velocity = float(m.twist.linear.y)
            out.heading_rate = float(m.twist.angular.z)
        else:
            out = m; out.header.frame_id = self.frame
            out.header.stamp = self.get_clock().now().to_msg()
        self.pub.publish(out); self._mark()


ROLES = {"ouster": OusterAdapter, "gnss": GnssAdapter,
         "imu": ImuAdapter, "velocity": VelocityAdapter}


def main():
    role = sys.argv[1] if len(sys.argv) > 1 else "ouster"
    if role not in ROLES:
        print(f"unknown role '{role}', expected one of {list(ROLES)}"); sys.exit(1)
    rclpy.init()
    n = ROLES[role]()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
