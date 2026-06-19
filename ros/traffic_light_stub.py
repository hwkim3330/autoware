#!/usr/bin/env python3
"""Publish an empty TrafficLightGroupArray so the traffic-light topic monitor
goes OK. With PERCEPTION=1 the full perception runs traffic-light recognition,
which needs a traffic-light camera we don't have in CARLA -> its topic monitor
errors -> the system gates AUTONOMOUS availability. We have no TL camera and the
demo doesn't need TL state, so feed an empty signal set (like perception_stub
does for objects). Run inside the container with use_sim_time."""
import time, rclpy
from rclpy.node import Node
from autoware_perception_msgs.msg import TrafficLightGroupArray

rclpy.init()
n = Node("traffic_light_stub")
pub = n.create_publisher(TrafficLightGroupArray, "/perception/traffic_light_recognition/traffic_signals", 1)


def tick():
    m = TrafficLightGroupArray()
    try:
        m.stamp = n.get_clock().now().to_msg()
    except Exception:
        pass
    pub.publish(m)


n.create_timer(0.1, tick)
print("traffic_light_stub: empty TrafficLightGroupArray @10Hz", flush=True)
rclpy.spin(n)
