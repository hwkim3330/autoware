#!/usr/bin/env python3
"""GNSS-only localizer for the OSM real-map demo (숭실대/판교).

On a generated OpenDRIVE world there is no pointcloud map, so NDT can't localize.
The CARLA interface publishes a ground-truth-accurate GNSS pose on
/sensing/gnss/pose_with_covariance (carla_ros.py) -- exactly like the real Niro's
RTK-GNSS. This node forwards that as the EKF pose input
(/localization/multimode/pose_with_covariance, which the MULTIMODE-patched launch
makes the EKF subscribe), so the EKF localizes purely on GNSS -- the Niro GNSS
localization pipeline, no PCD/NDT required.

It also publishes /multimode/mode = "GNSS_ONLY" so the tablet shows the mode.
"""
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from geometry_msgs.msg import PoseWithCovarianceStamped
from std_msgs.msg import String


class GnssOnlyLocalizer(Node):
    def __init__(self):
        super().__init__("gnss_only_localizer")
        self.set_parameters([Parameter("use_sim_time", Parameter.Type.BOOL, True)])
        be = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                        history=HistoryPolicy.KEEP_LAST)
        self.pub = self.create_publisher(
            PoseWithCovarianceStamped, "/localization/multimode/pose_with_covariance", be)
        self.pub_mode = self.create_publisher(String, "/multimode/mode", 1)
        # the interface publishes the GNSS pose here (ground-truth accurate)
        self.create_subscription(PoseWithCovarianceStamped,
                                 "/sensing/gnss/pose_with_covariance", self._on_gnss, be)
        self.create_timer(0.5, lambda: self.pub_mode.publish(String(data="GNSS_ONLY")))
        self._n = 0
        self.get_logger().info("GNSS-only localizer up (GNSS pose -> EKF, no PCD/NDT)")

    def _on_gnss(self, m):
        # forward straight through; tighten covariance so EKF trusts it (RTK-grade)
        out = m
        c = list(out.pose.covariance)
        c[0] = c[7] = 0.04        # ~0.2 m std on x,y
        c[35] = 0.01              # ~0.1 rad std on yaw
        out.pose.covariance = c
        self.pub.publish(out)
        self._n += 1
        if self._n % 100 == 0:
            self.get_logger().info(f"forwarded {self._n} GNSS poses")


def main():
    rclpy.init()
    n = GnssOnlyLocalizer()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
