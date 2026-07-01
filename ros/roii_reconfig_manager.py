#!/usr/bin/env python3
"""ROii Reconfiguration Manager — 장애 유형 분류 기반 주행 모드 전환 및 재구성 관리.

과제 요구: "장애 유형 분류와 주행 모드 전환을 위한 재구성 관리 기능 개발"

주행 모드 (DrivingMode):
  NORMAL          전체 센서 정상, 4-LiDAR 자율주행
  DEGRADED_3      라이다 1개 고장 → 3개로 재구성
  DEGRADED_2      라이다 2개 고장 → 2개로 재구성
  DEGRADED_1      라이다 3개 고장 → 1개로 재구성 (주의 필요)
  GNSS_FALLBACK   전체 LiDAR 고장 → GNSS 기반 측위 폴백
  MODULE_FAULT    핵심 모듈(localization/planning) 장애
  MRM             최소위험기동 (복구 불가 수준)

재구성 액션:
  - 고장 라이다 목록 보고 (injector가 already 처리)
  - multimode supervisor에 fallback 신호 전송 (LiDAR 전체 고장 시)
  - gateway로 재구성 상태 전달 → 태블릿 시각화

Status:
  /roii/reconfig_status  (std_msgs/String, JSON) — 1 Hz
"""

import json
import time
import collections
import threading

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from std_msgs.msg import String, Bool

LIDARS = ("front_g32", "rear_g32", "left_pandar", "right_pandar")

# 모드 우선순위 (숫자 클수록 심각)
MODE_PRIORITY = {
    "NORMAL": 0, "DEGRADED_3": 1, "DEGRADED_2": 2,
    "DEGRADED_1": 3, "GNSS_FALLBACK": 4, "MODULE_FAULT": 5, "MRM": 6,
}

MODE_DESC = {
    "NORMAL":       "전체 센서 정상 — 4-LiDAR 자율주행",
    "DEGRADED_3":   "LiDAR 1개 고장 — 3개로 재구성",
    "DEGRADED_2":   "LiDAR 2개 고장 — 2개로 재구성",
    "DEGRADED_1":   "LiDAR 3개 고장 — 1개로 재구성 (저하)",
    "GNSS_FALLBACK":"전체 LiDAR 고장 — GNSS 측위 폴백",
    "MODULE_FAULT": "자율주행 모듈 장애 — 수동 개입 필요",
    "MRM":          "최소위험기동 — 안전 정지",
}


class ReconfigManager(Node):
    def __init__(self):
        super().__init__("roii_reconfig_manager")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])

        self.lock = threading.Lock()
        self._last_report = None
        self._mode = "NORMAL"
        self._prev_mode = "NORMAL"
        # 장애 이벤트 이력 (최대 20개)
        self._history = collections.deque(maxlen=20)

        self.create_subscription(String, "/roii/fault_report", self._on_report, 1)

        self.pub_status  = self.create_publisher(String, "/roii/reconfig_status", 1)
        self.pub_inject  = self.create_publisher(String, "/multimode/inject", 1)
        self.pub_niro_f  = self.create_publisher(Bool, "/test/fault_injection/lidar", 1)

        self.create_timer(1.0, self._tick)
        self.get_logger().info("ROii reconfiguration manager up")

    def _on_report(self, msg):
        try:
            report = json.loads(msg.data)
        except Exception:
            return
        with self.lock:
            self._last_report = report
        self._evaluate(report)

    def _evaluate(self, report):
        sensors = report.get("sensors", {})
        modules = report.get("modules", {})
        active_lidars = report.get("active_lidars", 4)

        # 고장 라이다 목록
        faulty_lidars = [s for s in LIDARS
                         if sensors.get(s, {}).get("fault", "NONE") != "NONE"]

        # 모듈 장애
        loc_fault   = modules.get("localization", {}).get("fault", "NONE") != "NONE"
        plan_fault  = modules.get("planning",     {}).get("fault", "NONE") != "NONE"

        # 주행 모드 결정
        if loc_fault and plan_fault:
            new_mode = "MRM"
        elif loc_fault or plan_fault:
            new_mode = "MODULE_FAULT"
        elif active_lidars == 0:
            new_mode = "GNSS_FALLBACK"
        elif active_lidars == 1:
            new_mode = "DEGRADED_1"
        elif active_lidars == 2:
            new_mode = "DEGRADED_2"
        elif active_lidars == 3:
            new_mode = "DEGRADED_3"
        else:
            new_mode = "NORMAL"

        with self.lock:
            old_mode = self._mode
            self._mode = new_mode

        if new_mode != old_mode:
            ts = time.strftime("%H:%M:%S")
            event = {
                "ts": ts, "from": old_mode, "to": new_mode,
                "faulty": faulty_lidars,
                "desc": MODE_DESC.get(new_mode, ""),
            }
            with self.lock:
                self._history.append(event)
            self.get_logger().warn(
                f"MODE {old_mode} → {new_mode} | faulty={faulty_lidars} | {MODE_DESC[new_mode]}")

            # 재구성 액션
            if new_mode == "GNSS_FALLBACK":
                self.pub_inject.publish(String(data="lidar_fail"))
                self.pub_niro_f.publish(Bool(data=True))
                self.get_logger().warn("ACTION: multimode fallback → GNSS")
            elif old_mode == "GNSS_FALLBACK" and new_mode != "MRM":
                self.pub_inject.publish(String(data="clear"))
                self.pub_niro_f.publish(Bool(data=False))
                self.get_logger().info("ACTION: multimode restored → LIDAR")

    def _tick(self):
        with self.lock:
            report = self._last_report
            mode   = self._mode
            hist   = list(self._history)

        if report is None:
            return

        sensors = report.get("sensors", {})
        modules = report.get("modules", {})
        active  = report.get("active_lidars", 4)

        # 센서별 요약
        sensor_summary = {}
        for s in LIDARS:
            d = sensors.get(s, {})
            sensor_summary[s] = {
                "status": "OK" if d.get("fault") == "NONE" else d.get("fault", "?"),
                "hz": d.get("rate_hz", 0),
            }
        sensor_summary["gnss"] = {
            "status": "OK" if sensors.get("gnss", {}).get("fault") == "NONE"
                      else sensors.get("gnss", {}).get("fault", "?"),
            "hz": sensors.get("gnss", {}).get("rate_hz", 0),
            "cov": sensors.get("gnss", {}).get("cov_m2", 0),
        }
        sensor_summary["imu"] = {
            "status": "OK" if sensors.get("imu", {}).get("fault") == "NONE"
                      else sensors.get("imu", {}).get("fault", "?"),
            "hz": sensors.get("imu", {}).get("rate_hz", 0),
        }

        module_summary = {}
        for m in ("localization", "planning", "control"):
            d = modules.get(m, {})
            module_summary[m] = {
                "status": "OK" if d.get("fault") == "NONE" else d.get("fault", "?"),
                "hz": d.get("rate_hz", 0),
            }

        status = {
            "ts": time.strftime("%H:%M:%S"),
            "mode": mode,
            "mode_desc": MODE_DESC.get(mode, ""),
            "mode_level": MODE_PRIORITY.get(mode, 0),
            "active_lidars": active,
            "sensors": sensor_summary,
            "modules": module_summary,
            "history": hist[-5:],   # 최근 5개 이벤트
        }
        self.pub_status.publish(String(data=json.dumps(status)))


def main():
    rclpy.init()
    rclpy.spin(ReconfigManager())


if __name__ == "__main__":
    main()
