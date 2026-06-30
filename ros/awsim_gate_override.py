#!/usr/bin/env python3
"""AWSIM control gate override.

Autoware vehicle_cmd_gate can publish PARK/emergency during diagnostics even when
AWSIM itself is ready to accept commands. For AWSIM demos, keep the simulator in
AUTONOMOUS control mode, clear emergency, keep DRIVE gear, and forward the
trajectory follower control command directly to AWSIM's command topics.
"""
import time

import rclpy
from rclpy.node import Node
from rclpy.clock import Clock, ClockType
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy, HistoryPolicy

from autoware_control_msgs.msg import Control
from autoware_vehicle_msgs.msg import GearCommand
from autoware_vehicle_msgs.srv import ControlModeCommand
from tier4_vehicle_msgs.msg import VehicleEmergencyStamped


class AWSIMGateOverride(Node):
    def __init__(self):
        super().__init__('awsim_gate_override')
        qos = QoSProfile(
            depth=1,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
        )
        self.cmd_clock = Clock(clock_type=ClockType.SYSTEM_TIME)
        self.pub_control = self.create_publisher(Control, '/control/command/control_cmd', qos)
        self.pub_gear = self.create_publisher(GearCommand, '/control/command/gear_cmd', qos)
        self.pub_emergency = self.create_publisher(
            VehicleEmergencyStamped, '/control/command/emergency_cmd', qos)
        self.control_mode = self.create_client(ControlModeCommand, '/input/control_mode_request')
        self.last_control = None
        self.last_control_t = 0.0
        self.create_subscription(
            Control, '/control/trajectory_follower/control_cmd', self.on_control, 10)
        self.create_timer(0.05, self.tick)
        self.get_logger().info('AWSIM gate override active: emergency=false, gear=DRIVE')

    def on_control(self, msg):
        self.last_control = msg
        self.last_control_t = time.monotonic()

    def _stamp(self):
        return self.cmd_clock.now().to_msg()

    def _request_autonomous(self):
        if not self.control_mode.service_is_ready():
            return
        req = ControlModeCommand.Request()
        req.mode = ControlModeCommand.Request.AUTONOMOUS
        self.control_mode.call_async(req)

    def tick(self):
        now = self._stamp()
        emergency = VehicleEmergencyStamped()
        emergency.stamp = now
        emergency.emergency = False
        self.pub_emergency.publish(emergency)

        gear = GearCommand()
        gear.stamp = now
        gear.command = GearCommand.DRIVE
        self.pub_gear.publish(gear)

        if int(time.monotonic() * 2) % 4 == 0:
            self._request_autonomous()

        if self.last_control is not None and time.monotonic() - self.last_control_t < 0.5:
            cmd = self.last_control
            cmd.stamp = now
            self.pub_control.publish(cmd)


def main():
    rclpy.init()
    node = AWSIMGateOverride()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
