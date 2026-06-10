#!/usr/bin/env python3
"""Minimal perception stub: publishes EMPTY perception outputs so the planner
generates a trajectory without running heavy (camera/lidar) detection. Matches
the ROii camera-OFF setup — treats the road as clear (no dynamic objects)."""
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_msgs.msg import Header
from autoware_perception_msgs.msg import PredictedObjects, TrafficLightGroupArray
from sensor_msgs.msg import PointCloud2, PointField
from nav_msgs.msg import OccupancyGrid

class Stub(Node):
    def __init__(self):
        super().__init__("perception_stub")
        self.objs = self.create_publisher(PredictedObjects, "/perception/object_recognition/objects", 1)
        be = QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST)
        self.pc = self.create_publisher(PointCloud2, "/perception/obstacle_segmentation/pointcloud", be)
        # clear (all-free) occupancy grid so behavior_path has a drivable area
        # without the heavy occupancy_grid_map node (perception:=false).
        self.og = self.create_publisher(OccupancyGrid, "/perception/occupancy_grid_map/map", 1)
        self._og_res = 0.5; self._og_n = 300  # 150 m x 150 m @ 0.5 m, all free
        try:
            self.tl = self.create_publisher(TrafficLightGroupArray, "/perception/traffic_light_recognition/traffic_signals", 1)
        except Exception:
            self.tl = None
        self.create_timer(0.1, self.tick)
        self.get_logger().info("perception_stub: empty objects + obstacle pointcloud + clear occupancy grid")

    def hdr(self, frame):
        h = Header(); h.stamp = self.get_clock().now().to_msg(); h.frame_id = frame; return h

    def tick(self):
        po = PredictedObjects(); po.header = self.hdr("map"); self.objs.publish(po)
        pc = PointCloud2(); pc.header = self.hdr("base_link")
        pc.height = 1; pc.width = 0
        pc.fields = [PointField(name=n, offset=o, datatype=PointField.FLOAT32, count=1)
                     for n, o in (("x",0),("y",4),("z",8))]
        pc.is_bigendian = False; pc.point_step = 12; pc.row_step = 0
        pc.is_dense = True; pc.data = b""
        self.pc.publish(pc)
        og = OccupancyGrid(); og.header = self.hdr("base_link")
        n, res = self._og_n, self._og_res
        og.info.resolution = res; og.info.width = n; og.info.height = n
        og.info.origin.position.x = -n * res / 2.0
        og.info.origin.position.y = -n * res / 2.0
        og.info.origin.orientation.w = 1.0
        og.data = [0] * (n * n)   # all free
        self.og.publish(og)
        if self.tl:
            from autoware_perception_msgs.msg import TrafficLightGroupArray as T
            t = T(); t.stamp = self.get_clock().now().to_msg(); self.tl.publish(t)

def main():
    rclpy.init(); rclpy.spin(Stub())
main()
