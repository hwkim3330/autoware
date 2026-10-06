#!/usr/bin/env python3
"""Re-initialise Autoware localization from GNSS when NDT loses the car.

Seen on AWSIM Shinjuku (2026-10-06): after fast manual driving the NDT pose ran
230+ m away from GNSS while still reporting `converged`, and the dashboard,
routing and autonomy all followed the wrong pose. In simulation the GNSS pose is
reliable, so when the fused pose and GNSS disagree by more than GAP_M for
HOLD_S, this asks /api/localization/initialize to start over from GNSS (empty
pose list: GNSS position + NDT's own heading search), at most MAX_TRIES times in
a row before leaving recovery to Reset.

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
MAX_TRIES = 2         # consecutive failed reinits before giving up (Reset takes over)


class Watchdog(Node):
    def __init__(self):
        super().__init__("localization_watchdog")
        self.odom = None
        self.gnss = []          # (t, x, y, z)
        self.bad_since = None
        self.last_fix = 0.0
        self.tries, self.gave_up = 0, False
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
            if now - self.last_fix > COOLDOWN_S:     # held after a reinit: reset the budget
                self.tries, self.gave_up = 0, False
            return
        self.bad_since = self.bad_since or now
        if now - self.bad_since < HOLD_S or now - self.last_fix < COOLDOWN_S:
            return
        if self.tries >= MAX_TRIES:
            if not self.gave_up:
                self.get_logger().error(f"{self.tries} reinits did not hold -- giving up; use Reset")
                self.gave_up = True
            return
        self._reinit(gap)
        self.tries += 1
        self.last_fix, self.bad_since = now, None

    def _reinit(self, gap):
        """Ask Autoware to initialise from GNSS itself: an empty pose list makes the
        pose_initializer take the GNSS position and run NDT's multi-yaw search.

        The first version passed a pose with a heading taken from GNSS motion or,
        when stationary, from the current fused pose -- which is exactly the pose
        that had gone wrong. Every 20 s it re-seeded a parked car with a different
        bad heading (-97, 56, 140 ... deg), NDT scored 0, the pose jumped, and the
        controller swung the steering: the "wheel moving on its own" and the
        unexpected reversing on 2026-10-06."""
        if not self.cli.service_is_ready():
            self.get_logger().warn("initialize service not ready")
            return
        self.cli.call_async(InitializeLocalization.Request())
        self.get_logger().warn(f"NDT {gap:.0f} m off GNSS -> GNSS+NDT initialisation requested "
                               f"(try {self.tries + 1}/{MAX_TRIES})")


def main():
    rclpy.init()
    rclpy.spin(Watchdog())


if __name__ == "__main__":
    main()
