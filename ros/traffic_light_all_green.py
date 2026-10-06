#!/usr/bin/env python3
"""Publish GREEN for every traffic-light regulatory element in the lanelet map.

traffic_light_stub.py publishes an EMPTY TrafficLightGroupArray: that keeps the
topic monitor happy, but the traffic-light module reads a missing signal as
UNKNOWN and stops at the line. On AWSIM Shinjuku the car pulled away and then
held at the first stop line forever (velocity factor `traffic-signal`, 0.0 m),
with perception off and no V2I topic to read the simulator's real light states.

For a driving demo, an all-green signal per regulatory element lets the planner
through every junction. Run inside the container:
    python3 traffic_light_all_green.py /root/autoware_map/shinjuku/lanelet2_map.osm
"""
import sys
import xml.etree.ElementTree as ET

import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from autoware_perception_msgs.msg import (TrafficLightElement, TrafficLightGroup,
                                          TrafficLightGroupArray)


def traffic_light_ids(osm_path):
    ids = []
    for rel in ET.parse(osm_path).getroot().iter("relation"):
        tags = {t.get("k"): t.get("v") for t in rel.iter("tag")}
        if tags.get("type") == "regulatory_element" and tags.get("subtype") == "traffic_light":
            ids.append(int(rel.get("id")))
    return ids


def main():
    osm = sys.argv[1] if len(sys.argv) > 1 else "/root/autoware_map/shinjuku/lanelet2_map.osm"
    ids = traffic_light_ids(osm)
    rclpy.init()
    n = Node("traffic_light_all_green")
    n.set_parameters([Parameter("use_sim_time", Parameter.Type.BOOL, True)])
    pub = n.create_publisher(TrafficLightGroupArray,
                             "/perception/traffic_light_recognition/traffic_signals", 1)
    n.get_logger().info(f"publishing GREEN for {len(ids)} traffic-light groups from {osm}")

    def tick():
        m = TrafficLightGroupArray()
        m.stamp = n.get_clock().now().to_msg()
        for i in ids:
            g = TrafficLightGroup()
            g.traffic_light_group_id = i
            e = TrafficLightElement()
            e.color, e.shape, e.status, e.confidence = (TrafficLightElement.GREEN,
                                                        TrafficLightElement.CIRCLE,
                                                        TrafficLightElement.SOLID_ON, 1.0)
            g.elements = [e]
            m.traffic_light_groups.append(g)
        pub.publish(m)

    n.create_timer(0.1, tick)
    rclpy.spin(n)


if __name__ == "__main__":
    main()
