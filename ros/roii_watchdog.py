#!/usr/bin/env python3
"""ROii stack watchdog + 재구성 관리자 (통합).

과제: 장애 감지·진단 및 재구성 관리 소프트웨어 개발
  - 센서/모듈 상태 모니터링 (publisher count 기반, DDS 안전)
  - 장애 유형 분류: NONE/STALE/INJECTED
  - 주행 모드 전환: NORMAL→DEGRADED_3/2/1→GNSS_FALLBACK→MRM
  - /roii/reconfig_status 발행 → gateway → 태블릿

기존 watchdog 기능 유지:
  - perception_stub / gateway 자동 복구
  - /roii/watchdog ego/perception/gateway 상태
"""
import json
import collections
import os
import socket
import subprocess
import time

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_msgs.msg import String, Bool
from nav_msgs.msg import Odometry
from autoware_perception_msgs.msg import PredictedObjects

SETUP = "source /opt/autoware/setup.bash"
ENVX  = "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml"

LIDARS = ("front_g32", "rear_g32", "left_pandar", "right_pandar")

MODE_PRIORITY = {
    "NORMAL": 0, "DEGRADED_3": 1, "DEGRADED_2": 2,
    "DEGRADED_1": 3, "GNSS_FALLBACK": 4, "MODULE_FAULT": 5, "MRM": 6,
}
MODE_DESC = {
    "NORMAL":        "전체 센서 정상 — 4-LiDAR 자율주행",
    "DEGRADED_3":    "LiDAR 1개 고장 — 3개로 재구성",
    "DEGRADED_2":    "LiDAR 2개 고장 — 2개로 재구성",
    "DEGRADED_1":    "LiDAR 3개 고장 — 1개로 재구성 (저하)",
    "GNSS_FALLBACK": "전체 LiDAR 고장 — GNSS 측위 폴백",
    "MODULE_FAULT":  "자율주행 모듈 장애 — 수동 개입 필요",
    "MRM":           "최소위험기동 — 안전 정지",
}


def sh(cmd):
    subprocess.Popen(["bash", "-lc", cmd], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Watchdog(Node):
    def __init__(self):
        super().__init__("roii_watchdog")
        self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])

        # ── 기존 watchdog 상태 ──────────────────────────────────────
        self.t_obj  = 0.0
        self.t_odom = 0.0
        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(PredictedObjects, "/perception/object_recognition/objects",
                                 lambda m: setattr(self, "t_obj",  time.monotonic()), 1)
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 lambda m: setattr(self, "t_odom", time.monotonic()), be)

        # ── 재구성 관리 상태 ────────────────────────────────────────
        self._mode    = "NORMAL"
        self._history = collections.deque(maxlen=20)
        self._injector_status = {}   # /roii/fault_injector/status 최신값
        self._gnss_fault = "normal"  # /roii/gnss_fault/status 최신값

        # injector/gnss fault status 구독 (String, 작은 메시지, 안전)
        self.create_subscription(String, "/roii/fault_injector/status",
                                 self._on_inj, 1)
        self.create_subscription(String, "/roii/gnss_fault/status",
                                 self._on_gnss_fault, 1)

        # ── 발행 ────────────────────────────────────────────────────
        self.pub_watch   = self.create_publisher(String, "/roii/watchdog", 1)
        self.pub_reconfig = self.create_publisher(String, "/roii/reconfig_status", 1)
        self.pub_inject   = self.create_publisher(String, "/multimode/inject", 1)
        self.pub_niro_f   = self.create_publisher(Bool,   "/test/fault_injection/lidar", 1)

        # ── 환경 ────────────────────────────────────────────────────
        self.lanelet = os.environ.get("LANELET_OSM", "/root/autoware_map/Town04/lanelet2_map.osm")
        self.spawn   = os.environ.get("CARLA_SPAWN", "")
        self.disp    = os.environ.get("RVIZ_DISPLAY", ":1")
        self._obj_grace = time.monotonic() + 30
        self._gw_grace  = time.monotonic() + 30

        self.create_timer(2.0, self._tick)   # watchdog 주기 (5→2s)
        self.get_logger().info("ROii watchdog + 재구성 관리자 up")

    # ── injector status ─────────────────────────────────────────────
    def _on_inj(self, msg):
        try:
            self._injector_status = json.loads(msg.data)
        except Exception:
            pass

    def _on_gnss_fault(self, msg):
        try:
            d = json.loads(msg.data)
            self._gnss_fault = d.get("mode", "normal")
        except Exception:
            pass

    # ── 장애 감지 (publisher count 기반) ────────────────────────────
    def _detect(self):
        inj = self._injector_status
        sensors, active = {}, 0
        for s in LIDARS:
            mode = inj.get(s, {}).get("mode", "normal") if inj else "normal"
            if mode != "normal":
                fault = mode.upper()
            else:
                pubs = self.count_publishers(f"/sensing/lidar/{s}/pointcloud_before_sync")
                fault = "NONE" if pubs > 0 else "STALE"
            sensors[s] = {"fault": fault, "hz": 0.0}
            if fault == "NONE":
                active += 1

        gf = self._gnss_fault
        sensors["gnss"] = {
            "fault": gf.upper() if gf != "normal" else (
                "NONE" if self.count_publishers("/sensing/gnss/pose_with_covariance") > 0
                else "STALE"),
            "hz": 0.0,
        }
        sensors["imu"] = {
            "fault": "NONE" if self.count_publishers("/sensing/imu/imu_data") > 0 else "STALE",
            "hz": 0.0,
        }
        modules = {
            "localization": {"fault": "NONE" if self.count_publishers("/localization/kinematic_state") > 0 else "STALE", "hz": 0.0},
            "planning":     {"fault": "NONE" if self.count_publishers("/planning/scenario_planning/trajectory") > 0 else "STALE", "hz": 0.0},
            "control":      {"fault": "NONE" if self.count_publishers("/control/command/control_cmd") > 0 else "STALE", "hz": 0.0},
        }
        return sensors, modules, active

    # ── 모드 결정 ────────────────────────────────────────────────────
    def _evaluate(self, sensors, modules, active):
        loc_f  = modules["localization"]["fault"] != "NONE"
        plan_f = modules["planning"]["fault"] != "NONE"
        if loc_f and plan_f:
            new = "MRM"
        elif loc_f or plan_f:
            new = "MODULE_FAULT"
        elif active == 0:
            new = "GNSS_FALLBACK"
        elif active == 1:
            new = "DEGRADED_1"
        elif active == 2:
            new = "DEGRADED_2"
        elif active == 3:
            new = "DEGRADED_3"
        else:
            new = "NORMAL"

        old = self._mode
        if new != old:
            faulty = [s for s in LIDARS if sensors[s]["fault"] != "NONE"]
            ev = {"ts": time.strftime("%H:%M:%S"), "from": old, "to": new,
                  "faulty": faulty, "desc": MODE_DESC.get(new, "")}
            self._history.append(ev)
            self._mode = new
            self.get_logger().warn(f"MODE {old} → {new} | faulty={faulty}")
            if new == "GNSS_FALLBACK":
                self.pub_inject.publish(String(data="lidar_fail"))
                self.pub_niro_f.publish(Bool(data=True))
            elif old == "GNSS_FALLBACK":
                self.pub_inject.publish(String(data="clear"))
                self.pub_niro_f.publish(Bool(data=False))

    # ── 발행 ────────────────────────────────────────────────────────
    def _publish_reconfig(self, sensors, modules, active):
        sensor_summary = {}
        for s in LIDARS:
            d = sensors[s]
            sensor_summary[s] = {"status": "OK" if d["fault"] == "NONE" else d["fault"], "hz": d["hz"]}
        sensor_summary["gnss"] = {"status": "OK" if sensors["gnss"]["fault"] == "NONE" else sensors["gnss"]["fault"], "hz": 0.0, "cov": 0.0}
        sensor_summary["imu"]  = {"status": "OK" if sensors["imu"]["fault"]  == "NONE" else sensors["imu"]["fault"],  "hz": 0.0}
        module_summary = {m: {"status": "OK" if modules[m]["fault"] == "NONE" else modules[m]["fault"], "hz": modules[m]["hz"]}
                          for m in modules}
        status = {
            "ts": time.strftime("%H:%M:%S"),
            "mode": self._mode,
            "mode_desc": MODE_DESC.get(self._mode, ""),
            "mode_level": MODE_PRIORITY.get(self._mode, 0),
            "active_lidars": active,
            "sensors": sensor_summary,
            "modules": module_summary,
            "history": list(self._history)[-5:],
        }
        self.pub_reconfig.publish(String(data=json.dumps(status)))

    # ── 기존 watchdog 헬퍼 ──────────────────────────────────────────
    def _port_open(self, port):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        try:
            return s.connect_ex(("127.0.0.1", port)) == 0
        finally:
            s.close()

    def _restart_stub(self):
        self.get_logger().warn("perception STALE -> restarting stub")
        sh("pkill -9 -f perception_stub.py; sleep 1; " + ENVX + "; " + SETUP +
           "; python3 -u /root/perception_stub.py --ros-args -p use_sim_time:=true > /tmp/pstub.log 2>&1")
        self._obj_grace = time.monotonic() + 20

    def _restart_gateway(self):
        self.get_logger().warn("gateway 8765 down -> restarting")
        sh("pkill -9 -f ros_ws_gateway.py; sleep 1; " + ENVX +
           f"; export LANELET_OSM={self.lanelet}; export CARLA_SPAWN='{self.spawn}'; export RVIZ_DISPLAY={self.disp}; "
           + SETUP + "; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1")
        self._gw_grace = time.monotonic() + 25

    # ── 메인 tick ───────────────────────────────────────────────────
    def _tick(self):
        now = time.monotonic()

        # watchdog
        obj_ok  = (now - self.t_obj)  < 6.0 if self.t_obj  else False
        odom_ok = (now - self.t_odom) < 4.0 if self.t_odom else False
        if now > self._obj_grace and not obj_ok:
            self._restart_stub()
        gw_ok = self._port_open(8765)
        if now > self._gw_grace and not gw_ok:
            self._restart_gateway()
        self.pub_watch.publish(String(data=json.dumps({
            "perception": "OK" if obj_ok else "STALE",
            "gateway":    "OK" if gw_ok  else "DOWN",
            "ego":        "OK" if odom_ok else "LOST",
        })))

        # 재구성 감지 + 발행
        sensors, modules, active = self._detect()
        self._evaluate(sensors, modules, active)
        self._publish_reconfig(sensors, modules, active)


def main():
    rclpy.init()
    rclpy.spin(Watchdog())


if __name__ == "__main__":
    main()
