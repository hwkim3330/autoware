#!/usr/bin/env python3
"""
CarlaNiroAdapter — read-only adapter for the CARLA Niro simulation profile.

Subscribes the carla_niro topics. The Niro multimode telemetry rides on
std_msgs/String topics (mode + JSON status). Autoware operation/route state and
the planning trajectory use Autoware message packages that may not be importable
in every environment — those are guarded with try/except and warn+skip.
"""
from std_msgs.msg import String
from nav_msgs.msg import Odometry

from base_adapter import BaseAdapter, quat_to_yaw  # noqa: F401


class CarlaNiroAdapter(BaseAdapter):
    def subscribe(self):
        s = self.state

        # /niro/multimode/mode (String) -> localization_mode
        def _on_mode(msg):
            s.localization_mode = self.parse_string(msg) or "UNKNOWN"

        self._sub("multimode.mode_topic",
                  self._topic("multimode", "mode_topic"), String, _on_mode)

        # /niro/multimode/status (String JSON) -> localization fields
        def _on_status(msg):
            data = self.parse_json_string(msg)
            self.apply_multimode_status_json(data)

        self._sub("multimode.status_topic",
                  self._topic("multimode", "status_topic"), String, _on_status)

        # /niro/multimode/transition_event (String JSON) -> events
        def _on_event(msg):
            data = self.parse_json_string(msg)
            if data is None:
                data = self.parse_string(msg)
            self.push_event(data, "transition_event")

        self._sub("multimode.transition_event_topic",
                  self._topic("multimode", "transition_event_topic"),
                  String, _on_event)

        # /niro/multimode/transition_status (String JSON) -> events (empty -> warn)
        def _on_tstatus(msg):
            data = self.parse_json_string(msg)
            if data is None:
                data = self.parse_string(msg)
            self.push_event(data, "transition_status")

        self._sub("multimode.transition_status_topic",
                  self._topic("multimode", "transition_status_topic"),
                  String, _on_tstatus)

        # fused pose / twist (configured-but-may-be-empty)
        try:
            from geometry_msgs.msg import PoseWithCovarianceStamped

            def _on_fpose(msg):
                p = self.parse_pose_with_cov(msg)
                s.localization_converged = True

            self._sub("multimode.fused_pose_topic",
                      self._topic("multimode", "fused_pose_topic"),
                      PoseWithCovarianceStamped, _on_fpose)
        except Exception:
            self.log.warn("PoseWithCovarianceStamped unavailable; "
                          "fused_pose_topic skipped")

        try:
            from geometry_msgs.msg import TwistWithCovarianceStamped

            def _on_ftwist(msg):
                t = self.parse_twist_with_cov(msg)
                s.vehicle_speed_mps = t["speed_mps"]

            self._sub("multimode.fused_twist_topic",
                      self._topic("multimode", "fused_twist_topic"),
                      TwistWithCovarianceStamped, _on_ftwist)
        except Exception:
            self.log.warn("TwistWithCovarianceStamped unavailable; "
                          "fused_twist_topic skipped")

        # /localization/kinematic_state (Odometry) -> speed + converged
        def _on_odom(msg):
            d = self.parse_odometry(msg)
            s.vehicle_speed_mps = d["speed_mps"]
            s.localization_converged = True

        self._sub("autoware.odometry_topic",
                  self._topic("autoware", "odometry_topic"), Odometry, _on_odom)

        # trajectory (autoware_planning_msgs/Trajectory if importable)
        try:
            from autoware_planning_msgs.msg import Trajectory

            def _on_traj(msg):
                pts = msg.points
                if not pts:
                    s.trajectory = []
                    return
                step = max(1, len(pts) // 100)
                s.trajectory = [
                    [round(p.pose.position.x, 2), round(p.pose.position.y, 2)]
                    for p in pts[::step]
                ]

            self._sub("autoware.trajectory_topic",
                      self._topic("autoware", "trajectory_topic"),
                      Trajectory, _on_traj)
        except Exception:
            self.log.warn("autoware_planning_msgs/Trajectory unavailable; "
                          "trajectory_topic skipped")

        # operation mode + route state (autoware_adapi_v1_msgs if importable)
        OP_MODE = {0: "UNKNOWN", 1: "STOP", 2: "AUTONOMOUS", 3: "LOCAL",
                   4: "REMOTE"}
        ROUTE_STATE = {0: "UNKNOWN", 1: "UNSET", 2: "SET", 3: "ARRIVED",
                       4: "CHANGING"}
        try:
            from autoware_adapi_v1_msgs.msg import OperationModeState

            def _on_op(msg):
                s.operation_mode = OP_MODE.get(int(msg.mode), "UNKNOWN")

            self._sub("autoware.operation_mode_topic",
                      self._topic("autoware", "operation_mode_topic"),
                      OperationModeState, _on_op)
        except Exception:
            self.log.warn("autoware_adapi_v1_msgs/OperationModeState "
                          "unavailable; operation_mode_topic skipped")

        try:
            from autoware_adapi_v1_msgs.msg import RouteState

            def _on_route(msg):
                s.route_state = ROUTE_STATE.get(int(msg.state), "UNKNOWN")

            self._sub("autoware.route_state_topic",
                      self._topic("autoware", "route_state_topic"),
                      RouteState, _on_route)
        except Exception:
            self.log.warn("autoware_adapi_v1_msgs/RouteState unavailable; "
                          "route_state_topic skipped")

        # mrm_state (empty in this profile -> warn+skip)
        try:
            from autoware_adapi_v1_msgs.msg import MrmState
            MRM = {0: "UNKNOWN", 1: "NORMAL", 2: "MRM_OPERATING",
                   3: "MRM_SUCCEEDED", 4: "MRM_FAILED"}

            def _on_mrm(msg):
                s.mrm_state = MRM.get(int(msg.state), "UNKNOWN")

            self._sub("autoware.mrm_state_topic",
                      self._topic("autoware", "mrm_state_topic"),
                      MrmState, _on_mrm)
        except Exception:
            self.log.warn("autoware_adapi_v1_msgs/MrmState unavailable; "
                          "mrm_state_topic skipped")
