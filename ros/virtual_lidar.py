#!/usr/bin/env python3
"""Virtual LiDAR for the real-map (planning_simulator) demo.

planning_sim has NO sensors, so rviz/app look static vs CARLA's live cloud. This
node synthesizes a LiDAR-like scan from the 3D map: it loads the map point cloud
(NGII road cloud, with real elevation), and at 10 Hz emits the subset within R
metres of the ego as a live PointCloud2 that follows the car -- the CARLA "cloud
moves with the vehicle" feel, on the REAL precise map, no CARLA needed. It also
adds a faint sensor-origin ring so the scan reads as a sweep.

This is the spec's "Virtual Sensor Driver" idea (niro/niro_sensor_adapter) applied
to visualization: a map-derived virtual scan. (Not a physically-accurate raycast;
a visibility-radius slice, which is enough for a live 3D scene + a realistic feel.)

Inputs:
    /localization/kinematic_state (Odometry)  -- ego pose
    map cloud: --pcd <path> (read once) or falls back to /map/pointcloud_map
Outputs:
    /sensing/lidar/top/pointcloud_raw (PointCloud2, frame=map) -- live local scan
    /sensing/lidar/concatenated/pointcloud (same; what the rviz LiDAR display shows)
"""
import argparse
import struct
import sys
import math

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy
from nav_msgs.msg import Odometry
from sensor_msgs.msg import PointCloud2, PointField
from std_msgs.msg import Header


def load_pcd_xyz(path):
    """Load an ascii PCD (x y z) into an (N,3) float32 array."""
    pts = []
    with open(path) as f:
        data = False
        for line in f:
            if not data:
                if line.startswith("DATA"):
                    data = True
                continue
            p = line.split()
            if len(p) >= 3:
                try:
                    pts.append((float(p[0]), float(p[1]), float(p[2])))
                except ValueError:
                    pass
    return np.array(pts, dtype=np.float32) if pts else np.zeros((0, 3), np.float32)


class VirtualLidar(Node):
    def __init__(self, pcd_path):
        super().__init__("virtual_lidar")
        self.R = self.declare_parameter("radius_m", 60.0).value
        self.rate = self.declare_parameter("rate_hz", 10.0).value
        self.cloud = load_pcd_xyz(pcd_path) if pcd_path else np.zeros((0, 3), np.float32)
        self.get_logger().info(f"virtual_lidar: map cloud {len(self.cloud)} pts, R={self.R} m")
        self._ego = None

        be = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT,
                        history=HistoryPolicy.KEEP_LAST)
        self.create_subscription(Odometry, "/localization/kinematic_state",
                                 self._on_odom, 10)
        # map cloud fallback (transient_local) if no pcd given
        if len(self.cloud) == 0:
            tl = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                            history=HistoryPolicy.KEEP_LAST,
                            durability=DurabilityPolicy.TRANSIENT_LOCAL)
            self.create_subscription(PointCloud2, "/map/pointcloud_map",
                                     self._on_map, tl)
        self.pub_raw = self.create_publisher(PointCloud2, "/sensing/lidar/top/pointcloud_raw", be)
        self.pub_cat = self.create_publisher(PointCloud2, "/sensing/lidar/concatenated/pointcloud", be)
        self.create_timer(1.0 / self.rate, self._tick)

    def _on_odom(self, m):
        p = m.pose.pose.position
        self._ego = (p.x, p.y, p.z)

    def _on_map(self, msg):
        # parse the transient_local map cloud once
        if len(self.cloud) > 0:
            return
        n = msg.width * msg.height
        xyz = np.frombuffer(msg.data, dtype=np.uint8).reshape(n, msg.point_step)[:, :12]
        self.cloud = xyz.view(np.float32).reshape(n, 3).copy()
        self.get_logger().info(f"virtual_lidar: got map cloud from topic ({n} pts)")

    def _tick(self):
        if self._ego is None or len(self.cloud) == 0:
            return
        ex, ey, ez = self._ego
        d2 = (self.cloud[:, 0] - ex) ** 2 + (self.cloud[:, 1] - ey) ** 2
        local = self.cloud[d2 < self.R * self.R]
        if len(local) == 0:
            return
        self._publish(local)

    def _publish(self, pts):
        msg = PointCloud2()
        msg.header = Header()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = "map"
        msg.height = 1
        msg.width = len(pts)
        msg.fields = [
            PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
        ]
        msg.is_bigendian = False
        msg.point_step = 12
        msg.row_step = 12 * len(pts)
        msg.is_dense = True
        msg.data = pts.astype(np.float32).tobytes()
        self.pub_raw.publish(msg)
        self.pub_cat.publish(msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcd", default="")
    args, _ = ap.parse_known_args()
    rclpy.init()
    n = VirtualLidar(args.pcd)
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
