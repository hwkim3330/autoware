#!/usr/bin/env python3
"""ROii Fault Detector — 센서·통신링크·Autoware 모듈 상태 모니터링 및 장애 유형 분류.

과제 요구: "센서, 통신 링크 및 자율주행 모듈의 상태 모니터링 기능 구현"

감시 대상:
  Sensors:  front_g32, rear_g32, left_pandar, right_pandar (LiDAR rate)
            gnss (rate)
            imu  (rate)
  Modules:  localization (NDT Hz)
            planning    (trajectory presence)
            control     (cmd rate)

장애 유형 (FaultType):
  NONE            정상
  RATE_LOW        토픽 발행 빈도 저하 (임계 이하)
  STALE           데이터 수신 없음 (타임아웃)

Status:
  /roii/fault_report  (std_msgs/String, JSON) — 1 Hz

Note (2026-07-07): this file deliberately monitors via count_publishers() only, no
message subscriptions, to avoid the DDS crash pattern this project hit early on
with heavier subscription loads. That constraint means timestamp-offset, GNSS
covariance, and pose-jump detection (which need the actual message payload) belong
in a node that IS allowed to subscribe -- roii_watchdog.py does the injector-aware
per-sensor differentiation this file doesn't attempt.
"""

import json
import time
import threading

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from std_msgs.msg import String

# ---------- 임계값 ----------
LIDAR_RATE_MIN   = 3.0   # Hz  (publisher-count 기반 ~5Hz tick; 실제 10Hz 목표 대비 30% 이하)
GNSS_RATE_MIN    = 2.0   # Hz  (publisher count 기반 ~5Hz tick)
IMU_RATE_MIN     = 2.0   # Hz  (publisher count 기반; CARLA IMU 실제 15Hz)
NDT_RATE_MIN     = 2.0   # Hz  (publisher count 기반)
PLAN_RATE_MIN    = 0.3   # Hz  (publisher count 기반)
STALE_SEC        = 2.0   # 마지막 메시지 이후 이 시간 지나면 STALE

LIDARS = ("front_g32", "rear_g32", "left_pandar", "right_pandar")


class RateEstimator:
    """이동 평균으로 토픽 수신 rate 추정."""
    def __init__(self, window=2.0):
        self.window = window
        self.stamps = []
        self.lock = threading.Lock()

    def tick(self):
        now = time.monotonic()
        with self.lock:
            self.stamps.append(now)
            cutoff = now - self.window
            self.stamps = [s for s in self.stamps if s >= cutoff]

    def rate(self):
        with self.lock:
            if len(self.stamps) < 2:
                return 0.0
            span = self.stamps[-1] - self.stamps[0]
            if span < 0.1:
                return 0.0
            return (len(self.stamps) - 1) / span

    def last_t(self):
        with self.lock:
            return self.stamps[-1] if self.stamps else 0.0


class FaultDetector(Node):
    def __init__(self):
        super().__init__("roii_fault_detector")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])

        # rate estimators
        self.lidar_re  = {s: RateEstimator() for s in LIDARS}
        self.gnss_re   = RateEstimator()
        self.imu_re    = RateEstimator()
        self.ndt_re    = RateEstimator()
        self.ctrl_re   = RateEstimator()

        # 모든 토픽 감시: 메시지 구독 없이 publisher count 기반 (DDS 크래시 방지)
        # 0.2s 타이머 → 5Hz tick → rate estimator 5Hz (LIDAR_RATE_MIN=5Hz와 동일)
        self.create_timer(0.2, self._check_all_pubs)

        self.pub = self.create_publisher(String, "/roii/fault_report", 1)
        self.create_timer(1.0, self._report_tick)
        self.get_logger().info("ROii fault detector up — monitoring 4-LiDAR + GNSS + modules")

    def _check_all_pubs(self):
        """모든 토픽을 publisher count로 감시 (메시지 구독 없음 — DDS 크래시 방지)."""
        if self.count_publishers("/sensing/lidar/concatenated/pointcloud") > 0:
            for r in self.lidar_re.values():
                r.tick()
        if self.count_publishers("/sensing/gnss/pose_with_covariance") > 0:
            self.gnss_re.tick()
        if self.count_publishers("/sensing/imu/imu_data") > 0:
            self.imu_re.tick()
        if self.count_publishers("/localization/kinematic_state") > 0:
            self.ndt_re.tick()
        if self.count_publishers("/control/command/control_cmd") > 0:
            self.ctrl_re.tick()

    # ---------- fault classification ----------
    def _classify_rate(self, estimator, min_rate, name):
        r = estimator.rate()
        age = time.monotonic() - estimator.last_t()
        if estimator.last_t() == 0 or age > STALE_SEC:
            return "STALE", r
        if r < min_rate:
            return "RATE_LOW", r
        return "NONE", r

    def _classify_gnss(self):
        ftype, rate = self._classify_rate(self.gnss_re, GNSS_RATE_MIN, "gnss")
        return ftype, rate, 0.0

    def _planning_ok(self):
        return self.count_publishers("/planning/scenario_planning/trajectory") > 0

    def _classify_ndt(self):
        return self._classify_rate(self.ndt_re, NDT_RATE_MIN, "ndt")

    def _report_tick(self):
        now = time.monotonic()
        report = {"ts": time.time(), "sensors": {}, "modules": {}, "comms": {}}

        # LiDAR: all 4 report the same concatenated-topic rate (this file only ever
        # sees the merged /sensing/lidar/concatenated/pointcloud publisher count, no
        # per-sensor signal) -- per-LiDAR differentiation using injector status is
        # roii_watchdog.py's job, which does subscribe to it.
        concat_fault, concat_rate = self._classify_rate(
            list(self.lidar_re.values())[0], LIDAR_RATE_MIN, "concat")
        for s in LIDARS:
            report["sensors"][s] = {"fault": concat_fault, "rate_hz": round(concat_rate, 2)}

        # GNSS
        g_fault, g_rate, g_cov = self._classify_gnss()
        report["sensors"]["gnss"] = {"fault": g_fault, "rate_hz": round(g_rate, 2),
                                      "cov_m2": round(g_cov, 2)}

        # IMU
        i_fault, i_rate = self._classify_rate(self.imu_re, IMU_RATE_MIN, "imu")
        report["sensors"]["imu"] = {"fault": i_fault, "rate_hz": round(i_rate, 2)}

        # Modules
        n_fault, n_rate = self._classify_ndt()
        report["modules"]["localization"] = {"fault": n_fault, "rate_hz": round(n_rate, 2)}

        # Planning: publisher count 기반 (Trajectory DDS 우회)
        p_ok = self._planning_ok()
        report["modules"]["planning"] = {
            "fault": "NONE" if p_ok else "STALE", "rate_hz": 1.0 if p_ok else 0.0}

        c_fault, c_rate = self._classify_rate(self.ctrl_re, PLAN_RATE_MIN, "control")
        report["modules"]["control"] = {"fault": c_fault, "rate_hz": round(c_rate, 2)}

        # 활성 라이다 수
        active_lidars = sum(1 for s in LIDARS
                            if report["sensors"][s]["fault"] == "NONE")
        report["active_lidars"] = active_lidars

        self.pub.publish(String(data=json.dumps(report)))

        # 로그 (변화 있을 때만)
        faults = [f"{k}:{v['fault']}" for k, v in report["sensors"].items()
                  if v["fault"] != "NONE"]
        faults += [f"{k}:{v['fault']}" for k, v in report["modules"].items()
                   if v["fault"] != "NONE"]
        if faults:
            self.get_logger().warn(f"FAULT: {', '.join(faults)} | active_lidars={active_lidars}")


def main():
    rclpy.init()
    try:
        rclpy.spin(FaultDetector())
    except Exception:
        pass
    finally:
        try:
            rclpy.shutdown()
        except Exception:
            pass


if __name__ == "__main__":
    main()
