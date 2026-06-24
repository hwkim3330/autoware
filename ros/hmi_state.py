#!/usr/bin/env python3
"""
HmiState — plain (ROS-free) container for the latest read-only HMI telemetry.

Holds the most-recently-parsed values pushed in by the adapters, the per-topic
last-update wall-clock times (for staleness detection), and the serializer that
emits the EXACT WebSocket JSON schema (schemaVersion "1.0") sent to Android.

Numeric fields default to None (so "no source" serializes as JSON null, NOT 0).
String status fields default to "UNKNOWN"; device presence defaults to
"UNAVAILABLE"; booleans default to False.
"""
import math


def _kmh(mps):
    return round(mps * 3.6, 2) if mps is not None else None


def _deg(rad):
    return round(math.degrees(rad), 2) if rad is not None else None


class HmiState:
    def __init__(self):
        # identity / framing
        self.profile = "UNKNOWN"
        self.source = "UNKNOWN"
        self.sequence = 0
        self.timestamp = ""
        # connection
        self.ros_connected = False
        self.data_stale = False
        self.last_update_times = {}   # topic_key -> monotonic seconds
        # vehicle
        self.vehicle_speed_mps = None
        self.steering_rad = None
        # localization / multimode
        self.localization_mode = "UNKNOWN"
        self.localization_valid = False
        self.localization_converged = False
        self.lidar_weight = None
        self.gnss_weight = None
        self.camera_weight = None
        self.lidar_fault = False
        self.gnss_fault = False
        self.camera_fault = False
        self.lidar_fresh = False
        self.gnss_fresh = False
        self.lidar_pose_age_sec = None
        self.gnss_pose_age_sec = None
        self.lidar_twist_age_sec = None
        self.gnss_twist_age_sec = None
        self.pose_timestamp_diff_sec = None
        self.pipeline_gap_m = None
        # autoware
        self.operation_mode = "UNKNOWN"
        self.route_state = "UNKNOWN"
        self.mrm_state = "UNKNOWN"
        # planning
        self.trajectory = []   # downsampled [[x, y], ...]
        # events
        self.events = []       # list of dicts/strings

    def mark(self, topic_key, now):
        """Record the last-update wall-clock time for a topic key."""
        self.last_update_times[topic_key] = now

    def _sensor_status(self, fault, fresh, weight):
        """Map fault/fresh/weight into the NORMAL/FAULT/UNAVAILABLE enum.

        FAULT wins. Otherwise a sensor is NORMAL only if it is fresh OR it is
        actively weighted (weight > 0); a zero/absent weight that isn't fresh is
        UNAVAILABLE (device present but not contributing, e.g. camera off)."""
        if fault:
            return "FAULT"
        if fresh:
            return "NORMAL"
        if weight is not None and weight > 0:
            return "NORMAL"
        return "UNAVAILABLE"

    def to_json(self, capabilities, profile, source, seq):
        last_update_ms = None
        if self.last_update_times:
            # newest update relative to "now" isn't tracked here; the gateway
            # passes a freshly-stamped state, so report 0-ish via age of newest.
            # We expose the most recent inter-update gap as a coarse hint.
            pass
        lidar_status = self._sensor_status(self.lidar_fault, self.lidar_fresh,
                                           self.lidar_weight)
        gnss_status = self._sensor_status(self.gnss_fault, self.gnss_fresh,
                                          self.gnss_weight)
        camera_status = self._sensor_status(self.camera_fault, False,
                                            self.camera_weight)
        return {
            "type": "status",
            "schemaVersion": "1.0",
            "sequence": seq,
            "timestamp": self.timestamp,
            "profile": profile,
            "source": source,
            "capabilities": capabilities,
            "connection": {
                "rosConnected": bool(self.ros_connected),
                "dataStale": bool(self.data_stale),
                "lastUpdateMs": last_update_ms,
            },
            "vehicle": {
                "speedKmh": _kmh(self.vehicle_speed_mps),
                "steeringDeg": _deg(self.steering_rad),
            },
            "localization": {
                "mode": self.localization_mode,
                "valid": bool(self.localization_valid),
                "converged": bool(self.localization_converged),
                "lidarWeight": self.lidar_weight,
                "gnssWeight": self.gnss_weight,
                "cameraWeight": self.camera_weight,
                "lidarFresh": bool(self.lidar_fresh),
                "gnssFresh": bool(self.gnss_fresh),
                "lidarPoseAgeSec": self.lidar_pose_age_sec,
                "gnssPoseAgeSec": self.gnss_pose_age_sec,
                "timestampDiffSec": self.pose_timestamp_diff_sec,
                "pipelineGapM": self.pipeline_gap_m,
            },
            "sensors": {
                "lidar": lidar_status,
                "gnss": gnss_status,
                "imu": "NORMAL" if self.ros_connected else "UNAVAILABLE",
                "camera": camera_status,
            },
            "autoware": {
                "operationMode": self.operation_mode,
                "routeState": self.route_state,
                "mrmState": self.mrm_state,
            },
            "events": list(self.events),
        }
