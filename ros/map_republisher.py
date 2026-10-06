#!/usr/bin/env python3
"""Re-publish the latched vector map so late or missed subscribers get it.

The lanelet2 map goes out once on /map/vector_map as TRANSIENT_LOCAL. Under
AWSIM's FastDDS shared-memory transport that latched sample is occasionally not
delivered to a subscriber that matches during bring-up -- seen 2026-10-06:
motion_velocity_planner sat at "Waiting for the map", so the lane-driving
trajectory never existed and every engage timed out.

This node takes the map once and publishes it from a fresh TRANSIENT_LOCAL
publisher of its own: every subscriber matches the new publisher and receives
the stored sample. It republishes a few times during the first minute, then
stays alive holding the latched copy.

    python3 map_republisher.py --ros-args -p use_sim_time:=true
"""
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy, HistoryPolicy
from autoware_map_msgs.msg import LaneletMapBin

TOPIC = "/map/vector_map"


class MapRepublisher(Node):
    def __init__(self):
        super().__init__("map_republisher")
        qos = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                         reliability=ReliabilityPolicy.RELIABLE, history=HistoryPolicy.KEEP_LAST)
        self.pub = self.create_publisher(LaneletMapBin, TOPIC, qos)
        self.map = None
        self.sent = 0
        self.create_subscription(LaneletMapBin, TOPIC, self._on_map, qos)
        self.create_timer(15.0, self._tick)

    def _on_map(self, m):
        if self.map is None:
            self.map = m
            self.get_logger().info(f"got vector map ({len(m.data)} bytes); republishing")
            self._tick()

    def _tick(self):
        if self.map is None or self.sent >= 4:
            return
        self.pub.publish(self.map)
        self.sent += 1


def main():
    rclpy.init()
    rclpy.spin(MapRepublisher())


if __name__ == "__main__":
    main()
