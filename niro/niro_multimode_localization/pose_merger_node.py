#!/usr/bin/env python3
"""Pose Merger -- the heart of the Niro multimode localization (문서 15~16쪽).

Fuses the two independent localization pipelines (LiDAR NDT + GNSS/EKF) into the
final Ego Pose/Twist by per-mode weights, and publishes the active mode. Handles:
  - pose AND twist fusion (weighted position + slerp'd yaw + weighted twist)
  - per-input timestamp/stale check (a stale input loses its weight)
  - covariance blending
  - no output gap across a mode transition (weights ramp over transition_duration)
  - position/yaw jump measurement at each transition (transition_event)

Modes (config-driven weights, mode_policy in niro/config/pose_merger.yaml):
    normal      : lidar 0.5 / gnss 0.5
    lidar_fault : lidar 0.0 / gnss 1.0

Inputs (from the two pipelines + the fault/mode layer):
    /localization/niro/lidar/pose_with_covariance   (PoseWithCovarianceStamped)
    /localization/niro/lidar/twist_with_covariance  (TwistWithCovarianceStamped)
    /localization/niro/gnss/pose_with_covariance     "
    /localization/niro/gnss/twist_with_covariance    "
    /multimode/mode_request   (std_msgs/String: "normal"|"lidar_fault")  -- optional
    /adaptation/lidar_fault   (std_msgs/Bool)  -- from the E/E adaptation layer

Outputs:
    /localization/multimode/pose_with_covariance
    /localization/multimode/twist_with_covariance
    /multimode/mode             (std_msgs/String, active mode)
    /multimode/status           (std_msgs/String, JSON health)
    /multimode/transition_event (std_msgs/String, JSON: from,to,pos_jump,yaw_jump)
"""
import json
import math
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from geometry_msgs.msg import PoseWithCovarianceStamped, TwistWithCovarianceStamped
from std_msgs.msg import String, Bool


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def quat_z(yaw):
    return math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def ang_lerp(a, b, t):
    """Interpolate angle a->b by t along the shortest arc."""
    d = (b - a + math.pi) % (2 * math.pi) - math.pi
    return a + d * t


class PoseMerger(Node):
    def __init__(self):
        super().__init__("niro_pose_merger")
        p = self.declare_parameter
        self.w_lidar_normal = p("normal.lidar_weight", 0.5).value
        self.w_gnss_normal = p("normal.gnss_weight", 0.5).value
        # lidar_fault: trust GNSS only; gnss_fault: trust LiDAR only
        self.w_lidar_lfault = p("lidar_fault.lidar_weight", 0.0).value
        self.w_gnss_lfault = p("lidar_fault.gnss_weight", 1.0).value
        self.w_lidar_gfault = p("gnss_fault.lidar_weight", 1.0).value
        self.w_gnss_gfault = p("gnss_fault.gnss_weight", 0.0).value
        self.stale_sec = p("stale_threshold_sec", 0.4).value
        self.ts_diff_sec = p("max_input_timestamp_diff_sec", 0.2).value
        self.transition_sec = p("transition_duration_sec", 0.5).value
        self.rate_hz = p("output_rate_hz", 50.0).value

        self._lidar_pose = None; self._lidar_pose_t = 0.0
        self._lidar_twist = None; self._lidar_twist_t = 0.0
        self._gnss_pose = None; self._gnss_pose_t = 0.0
        self._gnss_twist = None; self._gnss_twist_t = 0.0
        self._gnss_fault = False        # from adaptation layer (if wired)
        self._req_mode = None          # external mode request
        self._lidar_fault = False      # from adaptation layer
        self._mode = "normal"
        # current (ramping) weights -> avoid output jump during a transition
        self._wl, self._wg = self.w_lidar_normal, self.w_gnss_normal
        self._wl_tgt, self._wg_tgt = self._wl, self._wg
        self._last_out_pose = None     # to measure jump

        be = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(PoseWithCovarianceStamped,
            "/localization/niro/lidar/pose_with_covariance", self._cb_lidar_pose, be)
        self.create_subscription(TwistWithCovarianceStamped,
            "/localization/niro/lidar/twist_with_covariance", self._cb_lidar_twist, be)
        self.create_subscription(PoseWithCovarianceStamped,
            "/localization/niro/gnss/pose_with_covariance", self._cb_gnss_pose, be)
        self.create_subscription(TwistWithCovarianceStamped,
            "/localization/niro/gnss/twist_with_covariance", self._cb_gnss_twist, be)
        # authoritative mode from the Mode Manager (falls back to the fault signal
        # + lidar staleness below if the manager isn't running)
        self.create_subscription(String, "/multimode/active_mode", self._cb_mode_req, 1)
        self.create_subscription(Bool, "/adaptation/lidar_fault",
                                 lambda m: setattr(self, "_lidar_fault", m.data), 1)
        self.create_subscription(Bool, "/adaptation/gnss_fault",
                                 lambda m: setattr(self, "_gnss_fault", m.data), 1)

        self.pub_pose = self.create_publisher(PoseWithCovarianceStamped,
            "/localization/multimode/pose_with_covariance", be)
        self.pub_twist = self.create_publisher(TwistWithCovarianceStamped,
            "/localization/multimode/twist_with_covariance", be)
        self.pub_mode = self.create_publisher(String, "/multimode/mode", 1)
        self.pub_status = self.create_publisher(String, "/multimode/status", 1)
        self.pub_event = self.create_publisher(String, "/multimode/transition_event", 10)

        self.create_timer(1.0 / self.rate_hz, self._tick)
        self.get_logger().info(
            "Niro Pose Merger up (normal %.2f/%.2f, lidar_fault %.2f/%.2f, gnss_fault %.2f/%.2f)" % (
                self.w_lidar_normal, self.w_gnss_normal, self.w_lidar_lfault, self.w_gnss_lfault,
                self.w_lidar_gfault, self.w_gnss_gfault))

    def _now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def _cb_lidar_pose(self, m): self._lidar_pose = m; self._lidar_pose_t = self._now()
    def _cb_gnss_pose(self, m): self._gnss_pose = m; self._gnss_pose_t = self._now()
    def _cb_lidar_twist(self, m): self._lidar_twist = m; self._lidar_twist_t = self._now()
    def _cb_gnss_twist(self, m): self._gnss_twist = m; self._gnss_twist_t = self._now()
    def _cb_mode_req(self, m):
        v = m.data.strip().lower()
        if v in ("normal", "lidar_fault", "gnss_fault", "unavailable"):
            self._req_mode = v

    def _fresh(self, t):
        return t > 0 and (self._now() - t) < self.stale_sec

    def _decide_mode(self):
        lidar_ok = self._fresh(self._lidar_pose_t)
        gnss_ok = self._fresh(self._gnss_pose_t)
        # both inputs dead -> unavailable (do NOT keep publishing a stale pose)
        if not lidar_ok and not gnss_ok:
            return "unavailable"
        # explicit request wins (when its sensor is alive)
        if self._req_mode in ("lidar_fault", "gnss_fault", "normal"):
            if self._req_mode == "lidar_fault" and gnss_ok:
                return "lidar_fault"
            if self._req_mode == "gnss_fault" and lidar_ok:
                return "gnss_fault"
            if self._req_mode == "normal" and lidar_ok and gnss_ok:
                return "normal"
        # auto: a fault flag OR a stale sensor forces fallback to the healthy one
        if self._lidar_fault or not lidar_ok:
            return "lidar_fault"      # -> GNSS only
        if self._gnss_fault or not gnss_ok:
            return "gnss_fault"       # -> LiDAR only
        return "normal"

    def _tick(self):
        new_mode = self._decide_mode()
        if new_mode != self._mode:
            self._begin_transition(self._mode, new_mode)
            self._mode = new_mode
        # ramp current weights toward target (no output gap / smooth)
        step = (1.0 / self.rate_hz) / max(1e-3, self.transition_sec)
        self._wl += max(-step, min(step, self._wl_tgt - self._wl))
        self._wg += max(-step, min(step, self._wg_tgt - self._wg))

        lp, gp = self._lidar_pose, self._gnss_pose
        lfresh, gfresh = self._fresh(self._lidar_pose_t), self._fresh(self._gnss_pose_t)
        # effective weights: drop a stale input, renormalize
        wl = self._wl if (lp and lfresh) else 0.0
        wg = self._wg if (gp and gfresh) else 0.0
        # timestamp-diff policy: if both fresh but their stamps differ by more than
        # max_input_timestamp_diff_sec, EXCLUDE the older input (don't fuse a lagging
        # pose with a current one). Default policy per spec.
        ts_diff = abs(self._lidar_pose_t - self._gnss_pose_t) if (lfresh and gfresh) else None
        ts_ok = (ts_diff is None) or (ts_diff <= self.ts_diff_sec)
        if ts_diff is not None and not ts_ok:
            if self._lidar_pose_t < self._gnss_pose_t:
                wl = 0.0      # lidar is older -> drop it
            else:
                wg = 0.0
        s = wl + wg
        if s < 1e-6 or self._mode == "unavailable":
            # both inputs unusable -> NOT valid; stop emitting a stale fused pose
            self._publish_status(lfresh, gfresh, valid=False, ts_diff=ts_diff, ts_ok=ts_ok)
            return
        wl, wg = wl / s, wg / s

        # --- fuse pose ---
        out = PoseWithCovarianceStamped()
        out.header.stamp = self.get_clock().now().to_msg()
        out.header.frame_id = "map"
        ref = lp if wl >= wg else gp
        op = out.pose.pose
        if wl > 0 and wg > 0:
            lpp, gpp = lp.pose.pose, gp.pose.pose
            op.position.x = wl * lpp.position.x + wg * gpp.position.x
            op.position.y = wl * lpp.position.y + wg * gpp.position.y
            op.position.z = wl * lpp.position.z + wg * gpp.position.z
            yaw = ang_lerp(yaw_of(gpp.orientation), yaw_of(lpp.orientation), wl)
            qz, qw = quat_z(yaw)
            op.orientation.z, op.orientation.w = qz, qw
            out.pose.covariance = [wl * a + wg * b for a, b in
                                   zip(lp.pose.covariance, gp.pose.covariance)]
        else:
            op.position = ref.pose.pose.position
            op.orientation = ref.pose.pose.orientation
            out.pose.covariance = list(ref.pose.covariance)
        self.pub_pose.publish(out)

        # --- fuse twist (separate freshness: never reuse a stale twist) ---
        ltf = self._fresh(self._lidar_twist_t) and self._lidar_twist is not None
        gtf = self._fresh(self._gnss_twist_t) and self._gnss_twist is not None
        a = self._lidar_twist.twist.twist if ltf else None
        b = self._gnss_twist.twist.twist if gtf else None
        if a or b:
            tw = TwistWithCovarianceStamped()
            tw.header = out.header; tw.header.frame_id = "base_link"
            if a and b and wl > 0 and wg > 0:
                tw.twist.twist.linear.x = wl * a.linear.x + wg * b.linear.x
                tw.twist.twist.linear.y = wl * a.linear.y + wg * b.linear.y
                tw.twist.twist.angular.z = wl * a.angular.z + wg * b.angular.z
            else:
                src = a if (a and wl >= wg) else (b if b else a)
                if src: tw.twist.twist = src
            self.pub_twist.publish(tw)

        self.pub_mode.publish(String(data=self._mode))
        self._publish_status(lfresh, gfresh, valid=True, wl=wl, wg=wg, out=op,
                             ts_diff=ts_diff, ts_ok=ts_ok, ltf=ltf, gtf=gtf)
        self._last_out_pose = (op.position.x, op.position.y, yaw_of(op.orientation))

    def _begin_transition(self, frm, to):
        if to == "lidar_fault":
            self._wl_tgt, self._wg_tgt = self.w_lidar_lfault, self.w_gnss_lfault
        elif to == "gnss_fault":
            self._wl_tgt, self._wg_tgt = self.w_lidar_gfault, self.w_gnss_gfault
        elif to == "unavailable":
            self._wl_tgt, self._wg_tgt = 0.0, 0.0
        else:
            self._wl_tgt, self._wg_tgt = self.w_lidar_normal, self.w_gnss_normal
        pos_jump = yaw_jump = 0.0
        # jump = difference between the two pipelines at switch time (what the
        # ego pose would discontinuously move if we hard-switched).
        if self._lidar_pose and self._gnss_pose:
            a, b = self._lidar_pose.pose.pose, self._gnss_pose.pose.pose
            pos_jump = math.hypot(a.position.x - b.position.x, a.position.y - b.position.y)
            yaw_jump = abs((yaw_of(a.orientation) - yaw_of(b.orientation) + math.pi)
                           % (2 * math.pi) - math.pi)
        self.pub_event.publish(String(data=json.dumps({
            "from": frm, "to": to,
            "pos_jump_m": round(pos_jump, 3), "yaw_jump_rad": round(yaw_jump, 4)})))
        self.get_logger().warn(f"mode {frm} -> {to} (pos_jump={pos_jump:.2f}m yaw_jump={yaw_jump:.3f})")

    def _age(self, t):
        return round(self._now() - t, 3) if t > 0 else None

    def _publish_status(self, lfresh, gfresh, valid, wl=0.0, wg=0.0, out=None,
                        ts_diff=None, ts_ok=True, ltf=False, gtf=False):
        self.pub_status.publish(String(data=json.dumps({
            "active_mode": self._mode, "mode": self._mode, "valid": valid,
            "lidar_fresh": lfresh, "gnss_fresh": gfresh,
            "lidar_weight": round(wl, 2), "gnss_weight": round(wg, 2),
            "lidar_pose_age_sec": self._age(self._lidar_pose_t),
            "gnss_pose_age_sec": self._age(self._gnss_pose_t),
            "lidar_twist_age_sec": self._age(self._lidar_twist_t),
            "gnss_twist_age_sec": self._age(self._gnss_twist_t),
            "lidar_twist_fresh": ltf, "gnss_twist_fresh": gtf,
            "timestamp_diff_sec": round(ts_diff, 3) if ts_diff is not None else None,
            "timestamp_diff_ok": ts_ok,
            # legacy fields kept for the existing app/gateway
            "input_ts_diff_sec": round(ts_diff, 3) if ts_diff is not None else None,
            "ts_diff_ok": ts_ok})))


def main():
    rclpy.init()
    n = PoseMerger()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
