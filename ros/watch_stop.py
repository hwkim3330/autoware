#!/usr/bin/env python3
"""Record what goes into ERROR at the moment the vehicle stops.

Written because the first diagnosis of the 242 m stop was not safe to act on.
`topic_state_monitor_transform_map_to_base_link` dominated the log with 59 ERROR
events, but drive_pangyo.py resets localization up to four times while it hunts
for a heading NDT will accept, and each reset legitimately drops the map ->
base_link TF. So those events could belong entirely to seeding and say nothing
about why the car stopped 200 m later. Rebuilding the Unity scene on that
inference would have been expensive and possibly pointless.

This subscribes to the vehicle, the MRM state and /diagnostics at once and prints
a timeline, so the ERROR set AT THE STOP is observed rather than inferred.

    python3 watch_stop.py [--watch 90]
"""
import argparse
import math
import time

import rclpy
from diagnostic_msgs.msg import DiagnosticArray
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy

RELIABLE = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                      history=HistoryPolicy.KEEP_LAST)


class Watch(Node):
    def __init__(self):
        super().__init__("watch_stop")
        self.odom = None
        self.errors = {}      # name -> message, only those currently at ERROR
        self.mrm = None
        # AWSIM's GNSS is noiseless and published straight off the ego transform,
        # so it is ground truth. Logging it beside NDT is the only way to see
        # whether NDT drifts from the start of the drive or only once the vehicle
        # has already left the road.
        self.gnss = None
        self.create_subscription(
            PoseStamped, "/sensing/gnss/pose", self._gnss,
            QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT))
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 self._odom, RELIABLE)
        self.create_subscription(DiagnosticArray, "/diagnostics",
                                 self._diag, QoSProfile(depth=10))
        # MrmState lives in autoware_adapi_v1_msgs; import lazily so the script
        # still runs if the API layer is not up.
        try:
            from autoware_adapi_v1_msgs.msg import MrmState
            self.create_subscription(MrmState, "/api/fail_safe/mrm_state",
                                     self._mrm, RELIABLE)
        except Exception as exc:      # noqa: BLE001
            print(f"  (MRM 구독 불가: {exc})")

    def _odom(self, m):
        self.odom = m

    def _gnss(self, m):
        self.gnss = m.pose.position

    def _mrm(self, m):
        self.mrm = m

    def _diag(self, m):
        for s in m.status:
            # level comes through as a single byte, not an int, in this binding.
            lvl = s.level if isinstance(s.level, int) else int.from_bytes(s.level, "big")
            if lvl >= 2:              # ERROR / STALE
                self.errors[s.name] = s.message
            else:
                self.errors.pop(s.name, None)

    def spin(self, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds:
            rclpy.spin_once(self, timeout_sec=0.1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", type=float, default=90.0)
    args = ap.parse_args()

    rclpy.init()
    w = Watch()
    w.spin(3.0)

    start = None
    stopped_at = None
    t0 = time.time()
    while time.time() - t0 < args.watch:
        w.spin(3.0)
        if w.odom is None:
            print("    측위 수신 없음")
            continue
        p = w.odom.pose.pose.position
        v = w.odom.twist.twist.linear.x
        if start is None:
            start = (p.x, p.y)
        moved = math.hypot(p.x - start[0], p.y - start[1])
        mrm = ""
        if w.mrm is not None:
            mrm = f" mrm=state{w.mrm.state}/behavior{w.mrm.behavior}"
        gap = ""
        if w.gnss is not None:
            gap = (f" |NDT-진실| {math.hypot(p.x - w.gnss.x, p.y - w.gnss.y):5.1f} m"
                   f" dz {p.z - w.gnss.z:+5.1f}")
        print(f"    t={time.time()-t0:5.0f}s v={v:6.2f} 이동 {moved:6.1f} m"
              f"{gap}{mrm}  ERROR {len(w.errors)}개")

        # The first time it is stationary after having moved, dump everything.
        if abs(v) < 0.2 and moved > 5.0 and stopped_at is None:
            stopped_at = moved
            print(f"    --- 정지 감지 ({moved:.1f} m) 시점의 ERROR 전체 ---")
            for name, msg in sorted(w.errors.items()):
                print(f"      {name}: {msg}")
            if not w.errors:
                print("      (ERROR 없음 -- 진단이 원인이 아님)")

    print(f"  최종: 이동 {moved:.1f} m, 정지 지점 "
          f"{'%.1f m' % stopped_at if stopped_at else '정지 안 함'}")
    print("  종료 시점 ERROR:")
    for name, msg in sorted(w.errors.items()):
        print(f"    {name}: {msg}")
    if not w.errors:
        print("    (없음)")


if __name__ == "__main__":
    main()
