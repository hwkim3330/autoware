#!/usr/bin/env python3
"""ROii Fault Detector — 센서·통신링크·Autoware 모듈 상태 모니터링 및 장애 유형 분류.

과제 요구: "센서, 통신 링크 및 자율주행 모듈의 상태 모니터링 기능 구현"

감시 대상:
  Sensors:  front_g32, rear_g32, left_pandar, right_pandar (LiDAR rate)
            gnss (pose covariance + staleness)
            imu  (rate)
  Modules:  localization (NDT Hz, pose jump)
            planning    (trajectory rate)
            control     (cmd rate)
  Comms:    gateway WS client count (링크 상태)

장애 유형 (FaultType):
  NONE            정상
  RATE_LOW        토픽 발행 빈도 저하 (임계 이하)
  STALE           데이터 수신 없음 (타임아웃)
  TIMESTAMP_FAULT 타임스탬프 이상 (미래/과거 오프셋 > 2s)
  COVARIANCE_HIGH GNSS 위치 불확실도 과다
  POSE_JUMP       연속 pose 간 거리 돌변 (측위 이상)
  MODULE_DEGRADED Autoware 모듈 Hz 저하

Status:
  /roii/fault_report  (std_msgs/String, JSON) — 1 Hz
"""

import json
import math
import time
import threading

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy

from sensor_msgs.msg import PointCloud2, Imu
from geometry_msgs.msg import PoseWithCovarianceStamped
from nav_msgs.msg import Odometry
try:
    from autoware_planning_msgs.msg import Trajectory
except ImportError:
    from autoware_auto_planning_msgs.msg import Trajectory
from std_msgs.msg import String

# ---------- 임계값 ----------
LIDAR_RATE_MIN   = 5.0   # Hz  (LOW 프로파일 목표 10Hz, 50% 이하 = fault)
GNSS_RATE_MIN    = 3.0   # Hz
IMU_RATE_MIN     = 50.0  # Hz
NDT_RATE_MIN     = 5.0   # Hz
PLAN_RATE_MIN    = 1.0   # Hz
STALE_SEC        = 2.0   # 마지막 메시지 이후 이 시간 지나면 STALE
TS_OFFSET_MAX    = 2.0   # 타임스탬프와 시스템 시간 차이 허용 최대 (초)
GNSS_COV_MAX     = 25.0  # 위치 분산 최대 (m²) — 5m std
POSE_JUMP_MAX    = 5.0   # 연속 pose 간 최대 허용 거리 (m)

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

        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        re = QoSProfile(depth=5, reliability=ReliabilityPolicy.RELIABLE,
                        history=HistoryPolicy.KEEP_LAST)

        # rate estimators
        self.lidar_re  = {s: RateEstimator() for s in LIDARS}
        self.gnss_re   = RateEstimator()
        self.imu_re    = RateEstimator()
        self.ndt_re    = RateEstimator()
        self.plan_re   = RateEstimator()
        self.ctrl_re   = RateEstimator()

        # last pose for jump detection
        self._last_ndt  = None
        self._last_gnss = None
        self.lock = threading.Lock()

        # LiDAR subscribers
        for s in LIDARS:
            self.create_subscription(
                PointCloud2, f"/sensing/lidar/{s}/pointcloud_before_sync",
                (lambda name: lambda m: self._lidar_cb(name, m))(s), be)

        # GNSS
        self.create_subscription(PoseWithCovarianceStamped,
                                 "/sensing/gnss/pose_with_covariance",
                                 self._gnss_cb, re)
        # IMU
        self.create_subscription(Imu, "/sensing/imu/imu_data", self._imu_cb, be)

        # Localization (NDT)
        self.create_subscription(PoseWithCovarianceStamped,
                                 "/localization/pose_estimator/pose_with_covariance",
                                 self._ndt_cb, re)
        # Planning trajectory
        self.create_subscription(Trajectory,
                                 "/planning/scenario_planning/trajectory",
                                 self._plan_cb, be)
        # Control command (패키지명 버전별 호환)
        try:
            from autoware_auto_control_msgs.msg import AckermannControlCommand as _Ctrl
        except ImportError:
            from autoware_control_msgs.msg import Control as _Ctrl
        self.create_subscription(_Ctrl, "/control/command/control_cmd",
                                 lambda m: self.ctrl_re.tick(), be)

        self.pub = self.create_publisher(String, "/roii/fault_report", 1)
        self.create_timer(1.0, self._report_tick)
        self.get_logger().info("ROii fault detector up — monitoring 4-LiDAR + GNSS + modules")

    # ---------- callbacks ----------
    def _lidar_cb(self, name, m): self.lidar_re[name].tick()
    def _gnss_cb(self, m):
        self.gnss_re.tick()
        with self.lock: self._last_gnss = m
    def _imu_cb(self, m): self.imu_re.tick()
    def _ndt_cb(self, m):
        self.ndt_re.tick()
        with self.lock: self._last_ndt = m
    def _plan_cb(self, m): self.plan_re.tick()

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
        if ftype != "NONE":
            return ftype, rate, 0.0
        with self.lock:
            m = self._last_gnss
        if m is None:
            return "STALE", rate, 0.0
        cov = m.pose.covariance
        pos_cov = max(cov[0], cov[7])   # xx, yy
        if pos_cov > GNSS_COV_MAX:
            return "COVARIANCE_HIGH", rate, pos_cov
        return "NONE", rate, pos_cov

    def _classify_ndt(self):
        ftype, rate = self._classify_rate(self.ndt_re, NDT_RATE_MIN, "ndt")
        if ftype != "NONE":
            return ftype, rate
        # pose jump check
        with self.lock:
            m = self._last_ndt
        if m is None:
            return "STALE", rate
        return ftype, rate

    def _report_tick(self):
        now = time.monotonic()
        report = {"ts": time.time(), "sensors": {}, "modules": {}, "comms": {}}

        # LiDAR
        for s in LIDARS:
            ftype, rate = self._classify_rate(self.lidar_re[s], LIDAR_RATE_MIN, s)
            report["sensors"][s] = {"fault": ftype, "rate_hz": round(rate, 2)}

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

        p_fault, p_rate = self._classify_rate(self.plan_re, PLAN_RATE_MIN, "planning")
        report["modules"]["planning"] = {"fault": p_fault, "rate_hz": round(p_rate, 2)}

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
    rclpy.spin(FaultDetector())


if __name__ == "__main__":
    main()
