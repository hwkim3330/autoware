#!/usr/bin/env python3
"""Seed localization, route, and engage autonomous driving on the Pangyo map.

Runs INSIDE the autoware container. Replaces the shell `ros2 service call`
sequence that run_pangyo_awsim.sh used to inline, for two reasons found by
measurement on 2026-07-28:

1. `ros2 topic echo` in this container throws out of ros2cli before printing, so
   the shell had no way to CHECK whether the seed took. It did not: the first
   seed left NDT at yaw -162.8 deg against a lane bearing of 109.7 deg -- 87.5
   deg out, far past what lanelet matching tolerates. Seeding through rclpy and
   reading the pose back turns that from invisible into a retry.
2. The seed covariance mattered. The shell used 1.0 on x/y; NDT wandered off it.
   0.25 with 0.01 on yaw holds -- verified stable at 104.2 deg over 18 s.

The other half of the fix is not here: the generated lanelet had no <MetaInfo>
element, so route_handler logged 'setMap() for invalid version map:' and held no
map, making every SetRoutePoints return 'The planned route is empty' regardless
of start and goal. That is fixed in gen_awsim_map_vworld.py.

    python3 drive_pangyo.py --seed X Y Z QZ QW --goal X Y QZ QW [--no-engage]
"""
import argparse
import math
import time

import rclpy
from autoware_adapi_v1_msgs.srv import (ChangeOperationMode, ClearRoute,
                                       InitializeLocalization, SetRoutePoints)
from autoware_adapi_v1_msgs.msg import OperationModeState
from geometry_msgs.msg import Pose, PoseWithCovariance, PoseWithCovarianceStamped
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import (DurabilityPolicy, HistoryPolicy, QoSProfile,
                        ReliabilityPolicy)

# Tight enough that NDT does not walk away from it, loose enough that it can
# still correct the metre or so of lateral offset the seed carries.
#
# Every entry must be a float, not an int: the message's setter asserts on the
# type of each of the 36 values, and a bare 0 fails it.
COV = [float(v) for v in
       (0.25, 0, 0, 0, 0, 0,
        0, 0.25, 0, 0, 0, 0,
        0, 0, 0.01, 0, 0, 0,
        0, 0, 0, 0.01, 0, 0,
        0, 0, 0, 0, 0.01, 0,
        0, 0, 0, 0, 0, 0.01)]


def yaw_of(o):
    return math.degrees(math.atan2(2 * (o.w * o.z + o.x * o.y),
                                   1 - 2 * (o.y * o.y + o.z * o.z)))


class Driver(Node):
    def __init__(self):
        super().__init__("drive_pangyo")
        self.odom = None
        self.opmode = None
        self.create_subscription(
            OperationModeState, "/api/operation_mode/state",
            lambda m: setattr(self, "opmode", m),
            QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                       durability=DurabilityPolicy.TRANSIENT_LOCAL,
                       history=HistoryPolicy.KEEP_LAST))
        self.create_subscription(
            Odometry, "/localization/kinematic_state", self._odom,
            QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                       history=HistoryPolicy.KEEP_LAST))
        self.init_cli = self.create_client(InitializeLocalization,
                                           "/api/localization/initialize")
        self.route_cli = self.create_client(SetRoutePoints,
                                            "/api/routing/set_route_points")
        self.mode_cli = self.create_client(ChangeOperationMode,
                                           "/api/operation_mode/change_to_autonomous")
        self.clear_cli = self.create_client(ClearRoute, "/api/routing/clear_route")
        self.stop_cli = self.create_client(ChangeOperationMode,
                                          "/api/operation_mode/change_to_stop")

    def _odom(self, m):
        self.odom = m

    def spin(self, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds:
            rclpy.spin_once(self, timeout_sec=0.1)

    def pose(self, wait=10.0):
        t0 = time.time()
        while self.odom is None and time.time() - t0 < wait:
            rclpy.spin_once(self, timeout_sec=0.1)
        if self.odom is None:
            return None
        p = self.odom.pose.pose
        return p.position.x, p.position.y, p.position.z, yaw_of(p.orientation)

    def call(self, cli, req, name, wait=60.0):
        if not cli.wait_for_service(timeout_sec=wait):
            print(f"    {name}: 서비스 없음")
            return None
        fut = cli.call_async(req)
        t0 = time.time()
        while not fut.done() and time.time() - t0 < wait:
            rclpy.spin_once(self, timeout_sec=0.1)
        return fut.result()

    def seed(self, x, y, z, qz, qw, want_yaw, tries=6, settle=12.0):
        """Seed, read back, retry. The read-back is the point."""
        req = InitializeLocalization.Request()
        pcs = PoseWithCovarianceStamped()
        pcs.header.frame_id = "map"
        pcs.pose = PoseWithCovariance()
        pcs.pose.pose = Pose()
        pcs.pose.pose.position.x, pcs.pose.pose.position.y = x, y
        pcs.pose.pose.position.z = z
        pcs.pose.pose.orientation.z, pcs.pose.pose.orientation.w = qz, qw
        pcs.pose.covariance = COV
        req.pose = [pcs]

        for attempt in range(1, tries + 1):
            r = self.call(self.init_cli, req, "initialize")
            ok = r is not None and r.status.success
            # 6 s was not enough. NDT has been observed taking most of 18 s to
            # settle onto a seeded heading; checking too early reads the
            # transient and throws away a seed that would have converged.
            self.spin(settle)
            got = self.pose()
            if got is None:
                print(f"    시드 {attempt}: 응답={ok} 위치 수신 없음")
                continue
            gx, gy, gz, gyaw = got
            err = abs((gyaw - want_yaw + 180) % 360 - 180)
            off = math.hypot(gx - x, gy - y)
            print(f"    시드 {attempt}: 응답={ok} -> ({gx:.1f},{gy:.1f},{gz:.1f}) "
                  f"yaw={gyaw:.1f}° (목표 {want_yaw:.1f}°, 오차 {err:.1f}°, 이격 {off:.1f} m)")
            if err < 15.0 and off < 5.0:
                return True
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", nargs=5, type=float, required=True,
                    metavar=("X", "Y", "Z", "QZ", "QW"))
    ap.add_argument("--goal", nargs=4, type=float, required=True,
                    metavar=("X", "Y", "QZ", "QW"))
    ap.add_argument("--goal-z", type=float, default=5.0)
    ap.add_argument("--no-engage", action="store_true")
    ap.add_argument("--watch", type=float, default=40.0)
    args = ap.parse_args()

    rclpy.init()
    d = Driver()

    # Re-runnable from any state. Left engaged with a route, the second run's
    # seed is refused with 'The vehicle is not stopped.' -- which is confusing,
    # because the vehicle IS stationary; what the API objects to is the
    # AUTONOMOUS operation mode, not the speed. So drop to stop and clear the
    # route BEFORE seeding, not just before routing.
    print("  [0] 정지 모드 + 기존 경로 해제")
    d.call(d.stop_cli, ChangeOperationMode.Request(), "change_to_stop", wait=10.0)
    d.call(d.clear_cli, ClearRoute.Request(), "clear_route", wait=10.0)
    d.spin(3.0)

    sx, sy, sz, sqz, sqw = args.seed
    want = math.degrees(2 * math.atan2(sqz, sqw))
    print(f"  [1] 측위 시드 ({sx:.1f}, {sy:.1f}) yaw={want:.1f}°")
    if not d.seed(sx, sy, sz, sqz, sqw, want):
        print("  실패: 시드가 안정되지 않음 -- 경로 설정 중단")
        return 1

    gx, gy, gqz, gqw = args.goal
    print(f"  [2] 경로 -> ({gx:.1f}, {gy:.1f})")
    # A route left over from an earlier run makes SetRoutePoints fail with "The
    # route is already set", which reads like a routing failure but is not one.
    d.call(d.clear_cli, ClearRoute.Request(), "clear_route", wait=10.0)
    d.spin(2.0)

    req = SetRoutePoints.Request()
    req.header.frame_id = "map"
    req.goal.position.x, req.goal.position.y = gx, gy
    req.goal.position.z = args.goal_z
    req.goal.orientation.z, req.goal.orientation.w = gqz, gqw
    r = d.call(d.route_cli, req, "set_route_points")
    if r is None or not r.status.success:
        msg = r.status.message if r is not None else "응답 없음"
        print(f"    실패: {msg}")
        return 1
    print("    경로 생성됨")

    if args.no_engage:
        return 0

    # Engage has to be RETRIED, not called once. Called ~2 s after routing it
    # comes back success=False even though is_autonomous_mode_available was
    # already true -- the planner has not published a trajectory yet. Measured on
    # the shipped Shinjuku map (2026-07-28): one call right after routing failed
    # and the vehicle sat still; the same call on its own a minute later returned
    # success=True and the vehicle drove 76.7 m at up to 11 m/s. So the map was
    # never the problem here -- the timing was.
    print("  [3] 자율주행 engage (모드가 AUTONOMOUS 될 때까지 재시도)")
    engaged = False
    for attempt in range(1, 7):
        r = d.call(d.mode_cli, ChangeOperationMode.Request(), "change_to_autonomous",
                   wait=40.0)
        ok = getattr(getattr(r, "status", None), "success", None)
        msg = getattr(getattr(r, "status", None), "message", "")
        d.spin(5.0)
        mode = getattr(d.opmode, "mode", None)
        avail = getattr(d.opmode, "is_autonomous_mode_available", None)
        print(f"    engage {attempt}: success={ok} mode={mode} 자율가능={avail}"
              + (f" '{msg}'" if msg else ""))
        if mode == 2:
            engaged = True
            break
    if not engaged:
        print("    실패: AUTONOMOUS 모드로 전환되지 않음")

    print(f"  [4] {args.watch:.0f}초 주행 관찰")
    t0 = time.time()
    start = d.pose()
    peak = 0.0
    while time.time() - t0 < args.watch:
        d.spin(4.0)
        p = d.pose(wait=2.0)
        if p is None or d.odom is None:
            continue
        v = d.odom.twist.twist.linear.x
        peak = max(peak, abs(v))
        moved = math.hypot(p[0] - start[0], p[1] - start[1]) if start else 0.0
        print(f"    t={time.time()-t0:4.0f}s  v={v:5.2f} m/s  "
              f"이동 {moved:6.1f} m  ({p[0]:.1f},{p[1]:.1f})")
    print(f"  최고 속도 {peak:.2f} m/s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
