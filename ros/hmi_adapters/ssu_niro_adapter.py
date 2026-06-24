#!/usr/bin/env python3
"""
SsuNiroAdapter — read-only adapter for the SSU real-vehicle Niro profile.

Subscribes only the multimode + multimode-localization topics that exist on the
real vehicle. All other configured topics are empty in ssu_niro.yaml, so the
base adapter warns and skips them. No SSU-custom message handling is done — only
the known std_msgs/geometry_msgs types are bound.
"""
from std_msgs.msg import String

from base_adapter import BaseAdapter  # noqa: F401


class SsuNiroAdapter(BaseAdapter):
    def subscribe(self):
        s = self.state

        # /multimode/mode (String) -> localization_mode
        def _on_mode(msg):
            s.localization_mode = self.parse_string(msg) or "UNKNOWN"

        self._sub("multimode.mode_topic",
                  self._topic("multimode", "mode_topic"), String, _on_mode)

        # /multimode/status (String JSON) -> localization fields
        def _on_status(msg):
            self.apply_multimode_status_json(self.parse_json_string(msg))

        self._sub("multimode.status_topic",
                  self._topic("multimode", "status_topic"), String, _on_status)

        # /multimode/transition_event (String JSON) -> events
        def _on_event(msg):
            data = self.parse_json_string(msg)
            if data is None:
                data = self.parse_string(msg)
            self.push_event(data, "transition_event")

        self._sub("multimode.transition_event_topic",
                  self._topic("multimode", "transition_event_topic"),
                  String, _on_event)

        # /multimode/transition_status (String JSON) -> events
        def _on_tstatus(msg):
            data = self.parse_json_string(msg)
            if data is None:
                data = self.parse_string(msg)
            self.push_event(data, "transition_status")

        self._sub("multimode.transition_status_topic",
                  self._topic("multimode", "transition_status_topic"),
                  String, _on_tstatus)

        # /localization/multimode/pose_with_covariance -> pose age + converged
        try:
            from geometry_msgs.msg import PoseWithCovarianceStamped

            def _on_pose(msg):
                p = self.parse_pose_with_cov(msg)
                s.localization_converged = True

            self._sub("multimode.fused_pose_topic",
                      self._topic("multimode", "fused_pose_topic"),
                      PoseWithCovarianceStamped, _on_pose)
        except Exception:
            self.log.warn("PoseWithCovarianceStamped unavailable; "
                          "fused_pose_topic skipped")

        # /localization/multimode/twist_with_covariance -> vehicle speed
        try:
            from geometry_msgs.msg import TwistWithCovarianceStamped

            def _on_twist(msg):
                t = self.parse_twist_with_cov(msg)
                s.vehicle_speed_mps = t["speed_mps"]

            self._sub("multimode.fused_twist_topic",
                      self._topic("multimode", "fused_twist_topic"),
                      TwistWithCovarianceStamped, _on_twist)
        except Exception:
            self.log.warn("TwistWithCovarianceStamped unavailable; "
                          "fused_twist_topic skipped")

        # Remaining configured topics (autoware.*, vehicle.*) are empty in the
        # ssu_niro profile -> base adapter warns + skips. Subscribe anyway so the
        # warnings fire exactly once per key (no-op for empty strings).
        for key in ("autoware.odometry_topic", "autoware.trajectory_topic",
                    "autoware.operation_mode_topic", "autoware.route_state_topic",
                    "autoware.mrm_state_topic", "vehicle.velocity_topic",
                    "vehicle.steering_topic"):
            section, field = key.split(".")
            if not self._topic(section, field):
                self.log.warn(f"{key} is not configured")
