#!/usr/bin/env python3
"""Multimode localization supervisor (숭실대 멀티모드 구조).

Sits between the pose estimators and the EKF: selects the localization source
by SENSOR AVAILABILITY and republishes it as the EKF input. The e2e launch is
patched so the EKF subscribes /localization/multimode/pose_with_covariance
instead of the NDT topic directly.

Modes:
  LIDAR_GNSS  (dual)    : NDT pose forwarded as-is (GNSS regularizes NDT).
  GNSS_IMU    (fallback): NDT stale or fault-injected -> GNSS position +
                          last-known yaw (IMU-stabilized via EKF feedback),
                          inflated covariance. The car keeps localizing.

Fault injection (demo): std_msgs/String on /multimode/inject:
  "lidar_fail" -> treat NDT as dead    "clear" -> back to auto selection
Mode is published on /multimode/mode and consumed by the tablet gateway.
"""
import math
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from geometry_msgs.msg import PoseWithCovarianceStamped
from nav_msgs.msg import Odometry
from std_msgs.msg import String

NDT_STALE_SEC = 1.5


class Supervisor(Node):
    def __init__(self):
        super().__init__("multimode_supervisor")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.ndt = None
        self.ndt_t = 0.0
        self.gnss = None
        self.ekf_yaw = 0.0
        self.injected_fail = False
        self.mode = "INIT"

        self.create_subscription(PoseWithCovarianceStamped,
                                 "/localization/pose_estimator/pose_with_covariance",
                                 self._on_ndt, 10)
        self.create_subscription(PoseWithCovarianceStamped,
                                 "/sensing/gnss/pose_with_covariance",
                                 self._on_gnss, 10)
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 self._on_ekf, 10)
        self.create_subscription(String, "/multimode/inject", self._on_inject, 1)
        self.pub_pose = self.create_publisher(
            PoseWithCovarianceStamped, "/localization/multimode/pose_with_covariance", 10)
        self.pub_mode = self.create_publisher(String, "/multimode/mode", 1)
        self.create_timer(0.5, self._mode_tick)
        self.get_logger().info("multimode supervisor up (LIDAR_GNSS <-> GNSS_IMU)")

    def _on_inject(self, m):
        self.injected_fail = (m.data == "lidar_fail")
        self.get_logger().warn(f"inject: {m.data} -> lidar_fail={self.injected_fail}")

    def _on_ekf(self, m):
        q = m.pose.pose.orientation
        self.ekf_yaw = math.atan2(2 * (q.w * q.z + q.x * q.y),
                                  1 - 2 * (q.y * q.y + q.z * q.z))

    def _lidar_ok(self):
        return (not self.injected_fail) and (time.monotonic() - self.ndt_t) < NDT_STALE_SEC

    def _on_ndt(self, m):
        self.ndt_t = time.monotonic()
        self.ndt = m
        if self._lidar_ok():
            self.pub_pose.publish(m)            # dual mode: NDT through, unchanged
            self._set_mode("LIDAR_GNSS")

    def _on_gnss(self, m):
        self.gnss = m
        if self._lidar_ok():
            return
        # fallback: GNSS position + last EKF yaw, inflated covariance
        out = PoseWithCovarianceStamped()
        out.header = m.header
        out.header.frame_id = "map"
        out.pose.pose.position = m.pose.pose.position
        out.pose.pose.orientation.z = math.sin(self.ekf_yaw / 2)
        out.pose.pose.orientation.w = math.cos(self.ekf_yaw / 2)
        cov = [0.0] * 36
        cov[0] = cov[7] = 1.0          # xy: GNSS-grade
        cov[14] = 4.0
        cov[21] = cov[28] = 0.1
        cov[35] = 0.3                  # yaw: held, low confidence
        out.pose.covariance = cov
        self.pub_pose.publish(out)
        self._set_mode("GNSS_IMU")

    def _set_mode(self, mode):
        if mode != self.mode:
            self.get_logger().warn(f"MODE {self.mode} -> {mode}")
            self.mode = mode

    def _mode_tick(self):
        self.pub_mode.publish(String(data=self.mode))


def main():
    rclpy.init()
    rclpy.spin(Supervisor())


if __name__ == "__main__":
    main()
