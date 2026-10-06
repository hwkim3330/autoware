#!/usr/bin/env python3
"""Re-initialise Autoware localization from GNSS when NDT loses the car.

Seen on AWSIM Shinjuku (2026-10-06): after fast manual driving the NDT pose ran
230+ m away from GNSS while still reporting `converged`, and the dashboard,
routing and autonomy all followed the wrong pose. In simulation the GNSS pose is
reliable, so when the fused pose and GNSS disagree by more than GAP_M for
HOLD_S, this calls /api/localization/initialize with the GNSS position and the
heading of recent GNSS motion (or the last fused heading when standing still).

Run inside the container:
    python3 localization_watchdog.py --ros-args -p use_sim_time:=true
"""
import math
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from geometry_msgs.msg import PoseWithCovarianceStamped
from nav_msgs.msg import Odometry
from autoware_adapi_v1_msgs.srv import InitializeLocalization

GAP_M = 15.0
HOLD_S = 3.0
COOLDOWN_S = 20.0


class Watchdog(Node):
    def __init__(self):
        super().__init__("localization_watchdog")
        self.odom = None
        self.gnss = []          # (t, x, y, z)
        self.bad_since = None
        self.last_fix = 0.0
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 lambda m: setattr(self, "odom", m), qos_profile_sensor_data)
        self.create_subscription(PoseWithCovarianceStamped, "/sensing/gnss/pose_with_covariance",
                                 self._on_gnss, qos_profile_sensor_data)
        self.cli = self.create_client(InitializeLocalization, "/api/localization/initialize")
        self.create_timer(0.5, self._check)
        self.get_logger().info(f"watching: reinit when |NDT - GNSS| > {GAP_M} m for {HOLD_S} s")

    def _on_gnss(self, m):
        p = m.pose.pose.position
        self.gnss.append((time.monotonic(), p.x, p.y, p.z))
        self.gnss = self.gnss[-20:]

    def _check(self):
        if self.odom is None or not self.gnss:
            return
        now = time.monotonic()
        t, gx, gy, gz = self.gnss[-1]
        if now - t > 5.0:                      # stale GNSS: cannot judge
            return
        o = self.odom.pose.pose.position
        gap = math.hypot(o.x - gx, o.y - gy)
        if gap < GAP_M:
            self.bad_since = None
            return
        self.bad_since = self.bad_since or now
        if now - self.bad_since < HOLD_S or now - self.last_fix < COOLDOWN_S:
            return
        yaw = self._gnss_heading()
        if yaw is None:
            q = self.odom.pose.pose.orientation
            yaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        self._reinit(gx, gy, gz, yaw, gap)
        self.last_fix, self.bad_since = now, None

    def _gnss_heading(self):
        # heading from the GNSS track over the last few samples, if the car moved enough
        if len(self.gnss) < 2:
            return None
        _, x0, y0, _ = self.gnss[max(0, len(self.gnss) - 5)]
        _, x1, y1, _ = self.gnss[-1]
        if math.hypot(x1 - x0, y1 - y0) < 2.0:
            return None
        return math.atan2(y1 - y0, x1 - x0)

    def _reinit(self, x, y, z, yaw, gap):
        if not self.cli.service_is_ready():
            self.get_logger().warn("initialize service not ready")
            return
        req = InitializeLocalization.Request()
        p = PoseWithCovarianceStamped()
        p.header.frame_id = "map"
        p.header.stamp = self.get_clock().now().to_msg()
        p.pose.pose.position.x, p.pose.pose.position.y, p.pose.pose.position.z = x, y, z
        p.pose.pose.orientation.z, p.pose.pose.orientation.w = math.sin(yaw / 2), math.cos(yaw / 2)
        cov = [0.0] * 36
        cov[0] = cov[7] = 1.0
        cov[35] = 0.1
        p.pose.covariance = cov
        req.pose = [p]
        self.cli.call_async(req)
        self.get_logger().warn(f"NDT {gap:.0f} m off GNSS -> reinitialised at ({x:.1f}, {y:.1f}), "
                               f"yaw {math.degrees(yaw):.0f} deg")


def main():
    rclpy.init()
    rclpy.spin(Watchdog())


if __name__ == "__main__":
    main()
