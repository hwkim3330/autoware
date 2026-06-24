#!/usr/bin/env python3
"""
BaseAdapter — shared subscription + parsing machinery for the read-only HMI
gateway. READ-ONLY: it creates SUBSCRIPTIONS only, never publishers/clients.

Subclasses declare which configured topic-keys map to which (msg_type, callback)
and call `self._sub(key, topic, msg_type, callback)`. The base:
  - skips EMPTY topic strings (logs a "<key> is not configured" warning), and
  - records the wall-clock last-update time in HmiState on every message.

A topic name change does NOT change the message type — each adapter binds the
concrete type it knows. Reusable parse helpers for the common message types live
here so subclasses stay small.
"""
import json
import math
import time

from rclpy.qos import (QoSProfile, DurabilityPolicy, ReliabilityPolicy,
                        HistoryPolicy)


def _qos(depth=10, transient_local=False, best_effort=False):
    return QoSProfile(
        depth=depth,
        history=HistoryPolicy.KEEP_LAST,
        durability=(DurabilityPolicy.TRANSIENT_LOCAL if transient_local
                    else DurabilityPolicy.VOLATILE),
        reliability=(ReliabilityPolicy.BEST_EFFORT if best_effort
                     else ReliabilityPolicy.RELIABLE),
    )


def quat_to_yaw(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y),
                      1 - 2 * (q.y * q.y + q.z * q.z))


def now_sec():
    return time.monotonic()


class BaseAdapter:
    def __init__(self, node, cfg, state):
        self.node = node
        self.cfg = cfg
        self.state = state
        self.log = node.get_logger()
        self._subs = []

    # ---- subscription helper -------------------------------------------------
    def _sub(self, key, topic, msg_type, callback, qos=None):
        """Subscribe key->topic with msg_type, or warn+skip if topic empty."""
        if not topic:
            self.log.warn(f"{key} is not configured")
            return None
        if qos is None:
            qos = _qos()

        def _wrapped(msg, _key=key, _cb=callback):
            try:
                _cb(msg)
            except Exception as e:  # never let one bad msg kill the spin
                self.log.warn(f"{_key} parse error: {e}")
            finally:
                self.state.mark(_key, now_sec())

        sub = self.node.create_subscription(msg_type, topic, _wrapped, qos)
        self._subs.append(sub)
        self.log.info(f"subscribed {key} -> {topic} [{msg_type.__name__}]")
        return sub

    def subscribe(self):  # pragma: no cover - overridden by subclasses
        raise NotImplementedError

    # ---- reusable config accessors ------------------------------------------
    def _topic(self, *path):
        d = self.cfg
        for p in path:
            if not isinstance(d, dict):
                return ""
            d = d.get(p, "")
        return d or ""

    # ---- reusable parse helpers ---------------------------------------------
    # geometry_msgs/PoseWithCovarianceStamped
    def parse_pose_with_cov(self, msg):
        p = msg.pose.pose
        return {
            "x": p.position.x, "y": p.position.y, "z": p.position.z,
            "yaw": quat_to_yaw(p.orientation),
            "stamp": self._stamp_sec(msg.header.stamp),
        }

    # geometry_msgs/TwistWithCovarianceStamped
    def parse_twist_with_cov(self, msg):
        v = msg.twist.twist.linear
        return {"speed_mps": math.hypot(v.x, v.y),
                "stamp": self._stamp_sec(msg.header.stamp)}

    # geometry_msgs/PoseStamped
    def parse_pose_stamped(self, msg):
        p = msg.pose
        return {"x": p.position.x, "y": p.position.y, "z": p.position.z,
                "yaw": quat_to_yaw(p.orientation),
                "stamp": self._stamp_sec(msg.header.stamp)}

    # geometry_msgs/TwistStamped
    def parse_twist_stamped(self, msg):
        v = msg.twist.linear
        return {"speed_mps": math.hypot(v.x, v.y),
                "stamp": self._stamp_sec(msg.header.stamp)}

    # nav_msgs/Odometry
    def parse_odometry(self, msg):
        v = msg.twist.twist.linear
        p = msg.pose.pose
        return {"speed_mps": math.hypot(v.x, v.y),
                "x": p.position.x, "y": p.position.y,
                "yaw": quat_to_yaw(p.orientation)}

    # nav_msgs/Path  (downsampled)
    def parse_path(self, msg, max_points=100):
        pts = msg.poses
        if not pts:
            return []
        step = max(1, len(pts) // max_points)
        return [[round(ps.pose.position.x, 2), round(ps.pose.position.y, 2)]
                for ps in pts[::step]]

    # std_msgs/String
    def parse_string(self, msg):
        return msg.data

    # std_msgs/String carrying JSON
    def parse_json_string(self, msg):
        try:
            return json.loads(msg.data)
        except Exception:
            return None

    # std_msgs/Bool
    def parse_bool(self, msg):
        return bool(msg.data)

    # diagnostic_msgs/DiagnosticArray -> list of {name, level, message}
    def parse_diagnostics(self, msg):
        out = []
        for st in msg.status:
            out.append({"name": st.name, "level": int(st.level),
                        "message": st.message})
        return out

    @staticmethod
    def _stamp_sec(stamp):
        try:
            return stamp.sec + stamp.nanosec * 1e-9
        except Exception:
            return None

    # ---- common JSON-status -> HmiState filling (shared by niro profiles) ----
    def apply_multimode_status_json(self, data):
        """Fill localization fields from a /multimode/status JSON dict.

        Tolerant of missing keys (leaves prior/None values). Accepts both
        camelCase and snake_case key spellings."""
        if not isinstance(data, dict):
            return
        s = self.state

        def g(*keys):
            for k in keys:
                if k in data and data[k] is not None:
                    return data[k]
            return None

        lw = g("lidarWeight", "lidar_weight")
        gw = g("gnssWeight", "gnss_weight")
        cw = g("cameraWeight", "camera_weight")
        if lw is not None:
            s.lidar_weight = float(lw)
        if gw is not None:
            s.gnss_weight = float(gw)
        if cw is not None:
            s.camera_weight = float(cw)

        valid = g("valid", "localizationValid")
        if valid is not None:
            s.localization_valid = bool(valid)
        conv = g("converged")
        if conv is not None:
            s.localization_converged = bool(conv)

        lf = g("lidarFresh", "lidar_fresh")
        gf = g("gnssFresh", "gnss_fresh")
        if lf is not None:
            s.lidar_fresh = bool(lf)
        if gf is not None:
            s.gnss_fresh = bool(gf)

        lfault = g("lidarFault", "lidar_fault")
        gfault = g("gnssFault", "gnss_fault")
        cfault = g("cameraFault", "camera_fault")
        if lfault is not None:
            s.lidar_fault = bool(lfault)
        if gfault is not None:
            s.gnss_fault = bool(gfault)
        if cfault is not None:
            s.camera_fault = bool(cfault)

        td = g("timestampDiffSec", "timestamp_diff_sec", "timestampDiff")
        if td is not None:
            s.pose_timestamp_diff_sec = float(td)
        gap = g("pipelineGapM", "pipeline_gap_m", "pipelineGap")
        if gap is not None:
            s.pipeline_gap_m = float(gap)

        lpa = g("lidarPoseAgeSec", "lidar_pose_age_sec")
        gpa = g("gnssPoseAgeSec", "gnss_pose_age_sec")
        lta = g("lidarTwistAgeSec", "lidar_twist_age_sec")
        gta = g("gnssTwistAgeSec", "gnss_twist_age_sec")
        if lpa is not None:
            s.lidar_pose_age_sec = float(lpa)
        if gpa is not None:
            s.gnss_pose_age_sec = float(gpa)
        if lta is not None:
            s.lidar_twist_age_sec = float(lta)
        if gta is not None:
            s.gnss_twist_age_sec = float(gta)

        mode = g("mode", "localizationMode")
        if mode is not None:
            s.localization_mode = str(mode)

    def push_event(self, data, kind):
        """Append a transition/event entry (dict or string), capped to 20."""
        evt = {"kind": kind, "data": data}
        self.state.events.append(evt)
        if len(self.state.events) > 20:
            self.state.events = self.state.events[-20:]
