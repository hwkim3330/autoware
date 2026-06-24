#!/usr/bin/env python3
"""Niro multimode bridge — runs the Niro dual-localization spec LIVE on the CARLA
stack as a telemetry/redundancy layer (without disturbing the proven driving path).

The proven driving path is unchanged: `multimode_supervisor.py` still selects the
EKF pose source (LIDAR_GNSS <-> GNSS_IMU) so the car keeps driving. This bridge
sits BESIDE it and demonstrates the Niro spec's richer Pose Merger — per-mode
weighted LiDAR/GNSS fusion with smooth weight ramping and transition-jump
measurement — feeding the Niro tablet dashboard. Same algorithm as
niro/niro_multimode_localization/pose_merger_node.py, wired to CARLA topics.

Inputs (CARLA Autoware graph):
    /localization/pose_estimator/pose_with_covariance  (NDT, the "LiDAR" pipeline)
    /sensing/gnss/pose_with_covariance                 (the "GNSS" pipeline)
    /localization/kinematic_state                      (Odometry -> twist + yaw)
    /multimode/inject   (String "lidar_fail"|"clear", from the tablet fault button)
    /test/fault_injection/lidar  (Bool, alt manual inject)

Outputs (consumed by the gateway -> tablet):
    /niro/multimode/mode             (String "normal"|"lidar_fault")
    /niro/multimode/status           (String JSON: weights, freshness, sensors, jump)
    /niro/multimode/transition_event (String JSON: from,to,pos_jump_m,yaw_jump_rad)
    /localization/niro/fused_pose    (PoseWithCovarianceStamped, the merged pose)
"""
import json
import math
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from geometry_msgs.msg import PoseWithCovarianceStamped
from nav_msgs.msg import Odometry
from std_msgs.msg import String, Bool

# Niro spec weights (niro/config/pose_merger.yaml)
W_LIDAR_NORMAL, W_GNSS_NORMAL = 0.5, 0.5
W_LIDAR_FAULT, W_GNSS_FAULT = 0.0, 1.0
STALE_SEC = 0.6          # CARLA NDT ~3-8 Hz; a bit looser than the 0.4 vehicle spec
TRANSITION_SEC = 0.5
RATE_HZ = 20.0


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def quat_z(yaw):
    return math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def ang_lerp(a, b, t):
    d = (b - a + math.pi) % (2 * math.pi) - math.pi
    return a + d * t


class NiroBridge(Node):
    def __init__(self):
        super().__init__("niro_bridge")
        self.set_parameters([Parameter("use_sim_time", Parameter.Type.BOOL, True)])

        self._lidar = None; self._lidar_t = 0.0
        self._gnss = None; self._gnss_t = 0.0
        self._twist = None
        self._injected = False
        self._mode = "normal"
        self._wl, self._wg = W_LIDAR_NORMAL, W_GNSS_NORMAL
        self._wl_tgt, self._wg_tgt = self._wl, self._wg

        self.create_subscription(PoseWithCovarianceStamped,
            "/localization/pose_estimator/pose_with_covariance", self._on_lidar, 10)
        self.create_subscription(PoseWithCovarianceStamped,
            "/sensing/gnss/pose_with_covariance", self._on_gnss, 10)
        self.create_subscription(Odometry, "/localization/kinematic_state", self._on_odom, 10)
        self.create_subscription(String, "/multimode/inject", self._on_inject, 1)
        self.create_subscription(Bool, "/test/fault_injection/lidar",
                                 lambda m: setattr(self, "_injected", m.data), 1)

        self.pub_mode = self.create_publisher(String, "/niro/multimode/mode", 1)
        self.pub_status = self.create_publisher(String, "/niro/multimode/status", 1)
        self.pub_event = self.create_publisher(String, "/niro/multimode/transition_event", 10)
        self.pub_pose = self.create_publisher(PoseWithCovarianceStamped,
            "/localization/niro/fused_pose", 10)
        self.create_timer(1.0 / RATE_HZ, self._tick)
        self.get_logger().info("Niro bridge up (live Pose Merger telemetry on CARLA)")

    def _now(self):
        return time.monotonic()

    def _on_lidar(self, m): self._lidar = m; self._lidar_t = self._now()
    def _on_gnss(self, m): self._gnss = m; self._gnss_t = self._now()
    def _on_odom(self, m): self._twist = m.twist.twist
    def _on_inject(self, m): self._injected = (m.data == "lidar_fail")

    def _fresh(self, t):
        return t > 0 and (self._now() - t) < STALE_SEC

    def _tick(self):
        lfresh = self._fresh(self._lidar_t)
        gfresh = self._fresh(self._gnss_t)
        new_mode = "lidar_fault" if (self._injected or not lfresh) else "normal"
        if new_mode != self._mode:
            self._begin_transition(self._mode, new_mode)
            self._mode = new_mode

        # ramp current weights toward target (smooth, no jump)
        if self._mode == "lidar_fault":
            self._wl_tgt, self._wg_tgt = W_LIDAR_FAULT, W_GNSS_FAULT
        else:
            self._wl_tgt, self._wg_tgt = W_LIDAR_NORMAL, W_GNSS_NORMAL
        step = (1.0 / RATE_HZ) / max(1e-3, TRANSITION_SEC)
        self._wl += max(-step, min(step, self._wl_tgt - self._wl))
        self._wg += max(-step, min(step, self._wg_tgt - self._wg))

        # effective weights: a stale input loses its weight, renormalize
        wl = self._wl if (self._lidar and lfresh) else 0.0
        wg = self._wg if (self._gnss and gfresh) else 0.0
        s = wl + wg
        valid = s > 1e-6
        if valid:
            wl, wg = wl / s, wg / s
            self._publish_fused(wl, wg)

        # sensor panel (single Ouster OS2-128 + RTK-GNSS + IMU)
        sensors = {
            "ouster_os2_128": {"ok": lfresh and not self._injected,
                               "hz": round(self._rate(self._lidar_t), 1)},
            "rtk_gnss": {"ok": gfresh, "fix": "RTK-FIX" if gfresh else "NO-FIX"},
            "imu": {"ok": self._twist is not None},
        }
        pos_jump = self._pipeline_gap()
        self.pub_mode.publish(String(data=self._mode))
        self.pub_status.publish(String(data=json.dumps({
            "mode": self._mode, "valid": valid,
            "lidar_weight": round(wl, 2), "gnss_weight": round(wg, 2),
            "lidar_fresh": lfresh, "gnss_fresh": gfresh,
            "injected": self._injected,
            "pipeline_gap_m": round(pos_jump, 2),
            "sensors": sensors})))

    def _rate(self, t):
        # rough liveness flag rate; CARLA NDT is bursty, so just report fresh/0
        return RATE_HZ if (self._now() - t) < STALE_SEC else 0.0

    def _pipeline_gap(self):
        if self._lidar and self._gnss:
            a, b = self._lidar.pose.pose, self._gnss.pose.pose
            return math.hypot(a.position.x - b.position.x, a.position.y - b.position.y)
        return 0.0

    def _publish_fused(self, wl, wg):
        lp, gp = self._lidar, self._gnss
        out = PoseWithCovarianceStamped()
        out.header.stamp = self.get_clock().now().to_msg()
        out.header.frame_id = "map"
        op = out.pose.pose
        if wl > 0 and wg > 0:
            a, b = lp.pose.pose, gp.pose.pose
            op.position.x = wl * a.position.x + wg * b.position.x
            op.position.y = wl * a.position.y + wg * b.position.y
            op.position.z = wl * a.position.z + wg * b.position.z
            yaw = ang_lerp(yaw_of(b.orientation), yaw_of(a.orientation), wl)
            op.orientation.z, op.orientation.w = quat_z(yaw)
            out.pose.covariance = [wl * x + wg * y for x, y in
                                   zip(lp.pose.covariance, gp.pose.covariance)]
        else:
            ref = lp if wl >= wg else gp
            op.position = ref.pose.pose.position
            op.orientation = ref.pose.pose.orientation
            out.pose.covariance = list(ref.pose.covariance)
        self.pub_pose.publish(out)

    def _begin_transition(self, frm, to):
        pos_jump = self._pipeline_gap()
        yaw_jump = 0.0
        if self._lidar and self._gnss:
            yaw_jump = abs((yaw_of(self._lidar.pose.pose.orientation)
                            - yaw_of(self._gnss.pose.pose.orientation) + math.pi)
                           % (2 * math.pi) - math.pi)
        self.pub_event.publish(String(data=json.dumps({
            "from": frm, "to": to,
            "pos_jump_m": round(pos_jump, 2), "yaw_jump_rad": round(yaw_jump, 3)})))
        self.get_logger().warn(f"NIRO mode {frm} -> {to} (gap={pos_jump:.2f}m)")


def main():
    rclpy.init()
    n = NiroBridge()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
