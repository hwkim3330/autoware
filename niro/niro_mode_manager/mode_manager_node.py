#!/usr/bin/env python3
"""Multimode Mode Manager (문서 3~5쪽).

Arbitrates mode-change requests from the E/E adaptation layer and the LiDAR fault
signal, drives the normal <-> lidar_fault transition, and publishes the
authoritative active mode that the Pose Merger follows. Records transition time,
keeps ROS connectivity through the switch, and reverts to normal when the sensor
recovers (with a debounce so it doesn't flap).

Inputs:
    /multimode/mode_request   (std_msgs/String: "normal"|"lidar_fault"|"auto")
    /adaptation/lidar_fault   (std_msgs/Bool)
Outputs:
    /multimode/active_mode       (std_msgs/String)
    /multimode/transition_status (std_msgs/String, JSON: from,to,result,duration_ms)
"""
import json
import rclpy
from rclpy.node import Node
from std_msgs.msg import String, Bool


class ModeManager(Node):
    def __init__(self):
        super().__init__("niro_mode_manager")
        self.recover_debounce_sec = self.declare_parameter("recover_debounce_sec", 2.0).value
        self.transition_timeout_sec = self.declare_parameter("transition_timeout_sec", 1.0).value

        self._req = "auto"          # external request; "auto" = follow the fault
        self._fault = False
        self._fault_clear_since = None
        self._mode = "normal"
        self._pending = None        # (target, t_start)

        self.create_subscription(String, "/multimode/mode_request", self._cb_req, 1)
        self.create_subscription(Bool, "/adaptation/lidar_fault", self._cb_fault, 1)
        self.pub_mode = self.create_publisher(String, "/multimode/active_mode", 1)
        self.pub_status = self.create_publisher(String, "/multimode/transition_status", 10)
        self.create_timer(0.05, self._tick)  # 20 Hz, keeps publishing through transitions
        self.get_logger().info("Niro Mode Manager up")

    def _now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def _cb_req(self, m):
        v = m.data.strip().lower()
        if v in ("normal", "lidar_fault", "auto"):
            self._req = v

    def _cb_fault(self, m):
        self._fault = m.data
        if not m.data:
            self._fault_clear_since = self._fault_clear_since or self._now()
        else:
            self._fault_clear_since = None

    def _target_mode(self):
        if self._req == "lidar_fault":
            return "lidar_fault"
        if self._req == "normal":
            return "normal"
        # auto: fault -> lidar_fault; recovery -> normal after debounce
        if self._fault:
            return "lidar_fault"
        if self._mode == "lidar_fault":
            if self._fault_clear_since and (self._now() - self._fault_clear_since) >= self.recover_debounce_sec:
                return "normal"
            return "lidar_fault"   # hold until debounce elapses
        return "normal"

    def _tick(self):
        tgt = self._target_mode()
        if tgt != self._mode and self._pending is None:
            self._pending = (tgt, self._now())
            self.get_logger().warn(f"transition START {self._mode} -> {tgt}")
        if self._pending is not None:
            tgt, t0 = self._pending
            elapsed = self._now() - t0
            # capture the ORIGIN mode BEFORE committing (was reading self._mode
            # after assignment -> from_mode wrongly equalled the target).
            from_mode = self._mode
            # transition_timeout_sec: this is an immediate-commit model (the Pose
            # Merger does the smooth weight ramp), so a transition cannot "time
            # out"; we still flag it if elapsed somehow exceeds the budget.
            result = "success" if elapsed <= self.transition_timeout_sec else "slow"
            self._mode = tgt
            self.pub_status.publish(String(data=json.dumps({
                "from_mode": from_mode, "to": tgt, "result": result,
                "duration_ms": round(elapsed * 1000.0, 1)})))
            self._pending = None
        # publish authoritative mode continuously (no gap)
        self.pub_mode.publish(String(data=self._mode))


def main():
    rclpy.init()
    n = ModeManager()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
