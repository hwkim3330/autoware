#!/usr/bin/env python3
"""Feeds the ROii 4-lidar pipeline (fault_injector -> concatenator) from ONE
360-degree roof-mounted lidar instead of 4 separately-spawned corner lidars.

Why: CARLA's sensor.lidar.ray_cast's IgnoreActor only ignores the sensor
itself, never the parent vehicle (RayCastSemanticLidar.cpp) -- every
corner-mounted lidar in the original 4-lidar suite self-occludes on the
vehicle's own body for a real, yaw-independent ~90-115deg dead zone (measured
live on the CARLA actor, documented in sensor_kit_calibration_roii.yaml and
docs/roii_lidar_carla_autoware.md; filed upstream as carla-simulator/carla#9804).
Not fixable from this side of the engine.

Fix: spawn ONE lidar at roof height (clear of the body silhouette from every
azimuth -- same reasoning as why real AV rooftop lidars sit above the
greenhouse line), then slice its point cloud into the same 4 named streams
the rest of the pipeline (fault_injector, health_monitor, concatenator,
sensor_kit TF) already expects, by azimuth angle -- matching each virtual
sensor's original yaw + horizontal_fov exactly, INCLUDING the original
design's intentional overlap between the fore/aft and side sensors (that
redundancy was real ROii design, not a bug -- preserved here since it costs
nothing once occlusion isn't a scarcity anymore).

Requires sensor_kit_calibration_roii.yaml's 4 virtual sensor entries
(roii_front_g32_base_link etc.) to be co-located with the roof sensor -- this
node republishes RAW (unrotated/untranslated) points from the roof sensor's
own frame, so the concatenator's TF-based transform-to-base_link only comes
out correct if each virtual frame's declared pose IS the roof sensor's pose.
"""
import math

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
import sensor_msgs_py.point_cloud2 as pc2
from sensor_msgs.msg import PointCloud2, PointField
from std_msgs.msg import Header

# (center_deg, half_width_deg) -- each virtual sensor's mount yaw +
# horizontal_fov/2 from sensor_mapping_roii_lidar_low.yaml (front/rear: 135deg
# FOV around yaw 0/180; left/right pandar: 220deg FOV around yaw +/-90).
#
# Azimuth is atan2(y, x) on the PUBLISHED cloud, which is already ROS/REP-103:
# autoware_carla_interface does `lidar_data[:, 1] *= -1` (carla_ros.py) when it
# converts from CARLA's left-handed frame, so +y is LEFT and +90deg is LEFT.
# The centers below were originally taken straight from the corner-mount
# calibration, which had been authored in CARLA's convention (+y right) -- so
# left_pandar was slicing the RIGHT side of the car and vice versa. Nothing was
# missing from the concatenated cloud (the pair is symmetric), but every
# per-sensor consumer had the sides transposed: injecting a fault into
# "left_pandar" blacked out the vehicle's right side and the tablet lit up the
# wrong side of the car. All 4 virtual frames sit co-located on the roof with
# yaw 0, so these azimuth centers are the ONLY thing assigning a physical
# direction to a name -- there is no TF to cross-check them against.
SLICES = {
    "front_g32": (0.0, 67.5),
    "rear_g32": (180.0, 67.5),
    "left_pandar": (90.0, 110.0),
    "right_pandar": (-90.0, 110.0),
}


def angle_in_slice(az_deg, center, half_width):
    d = (az_deg - center + 180.0) % 360.0 - 180.0
    return abs(d) <= half_width


class RoiiLidarSlicer(Node):
    def __init__(self):
        super().__init__("roii_lidar_slicer")
        be = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST, depth=5)
        self.pubs = {
            name: self.create_publisher(PointCloud2, f"/sensing/lidar/{name}/pointcloud_raw", be)
            for name in SLICES
        }
        self.create_subscription(PointCloud2, "/sensing/lidar/roof/pointcloud_raw", self._on_cloud, be)
        self._count = 0
        self.get_logger().info("roii_lidar_slicer up -- slicing /sensing/lidar/roof into %s"
                                % ", ".join(SLICES))

    def _on_cloud(self, msg: PointCloud2):
        self._count += 1
        try:
            # Match autoware_carla_interface's own carla_ros.py lidar() field
            # layout exactly (x,y,z f4 / intensity,return_type u1 / channel u2)
            # -- the roof source topic is already in this format (published by
            # that same code path), so this is a read-through, not a guess.
            # A prior version only read/republished x,y,z,intensity as float32
            # and silently dropped return_type/channel: the downstream
            # PointCloudConcatenateDataSynchronizerComponent never emitted a
            # single concatenated_raw message against that malformed layout
            # even with 500+ correctly-timed before_sync messages on all 4
            # topics (confirmed live, 2026-07-09) -- it needs those fields.
            pts = list(pc2.read_points(
                msg, field_names=("x", "y", "z", "intensity", "return_type", "channel"), skip_nans=True))
        except Exception as e:
            if self._count % 50 == 1:
                self.get_logger().warn(f"read_points failed: {e}")
            return

        buckets = {name: [] for name in SLICES}
        for p in pts:
            x, y = float(p[0]), float(p[1])
            az = math.degrees(math.atan2(y, x))
            for name, (center, half_width) in SLICES.items():
                if angle_in_slice(az, center, half_width):
                    buckets[name].append((p[0], p[1], p[2], p[3], p[4], p[5]))

        fields = [
            PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
            PointField(name="intensity", offset=12, datatype=PointField.UINT8, count=1),
            PointField(name="return_type", offset=13, datatype=PointField.UINT8, count=1),
            PointField(name="channel", offset=14, datatype=PointField.UINT16, count=1),
        ]
        # Each output gets ITS OWN stamp (node clock at publish time), not the
        # single source message's header reused verbatim -- reusing one header
        # made all 4 sliced streams byte-identical timestamps, unlike 4
        # genuinely independent sensors (which always differ by at least jitter).
        # The downstream PointCloudConcatenateDataSynchronizerComponent (naive
        # matching) never produced a single concatenated_raw message with the
        # identical-stamp version, even after 500+ synchronized before_sync
        # messages on all 4 topics (confirmed live, 2026-07-09) -- giving each
        # slice a distinct stamp fixed it.
        now = self.get_clock().now().to_msg()
        for name, rows in buckets.items():
            header = Header()
            header.stamp = now
            header.frame_id = f"roii_{name}"
            out = pc2.create_cloud(header, fields, rows)
            self.pubs[name].publish(out)


def main():
    rclpy.init()
    node = RoiiLidarSlicer()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
