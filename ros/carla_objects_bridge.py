#!/usr/bin/env python3
"""CARLA ground-truth -> Autoware PredictedObjects bridge.

Reads CARLA actors (vehicles + pedestrians, excluding the ego) and publishes
them on /perception/object_recognition/objects so Autoware's planning slows /
stops / avoids them -- WITHOUT the heavy real perception pipeline. This OWNS the
objects topic (the perception_stub must NOT also publish empty objects, or they
flicker); it publishes an empty list when no actors are present, keeping the
perception rate-check satisfied.

CARLA -> Autoware map frame: x=cx, y=-cy, yaw=-cyaw (the standard y/yaw flip).
Run inside the container after localization is up.
"""
import math
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile
from rclpy.parameter import Parameter
from autoware_perception_msgs.msg import (
    PredictedObjects, PredictedObject, PredictedObjectKinematics,
    ObjectClassification, Shape, PredictedPath)
from geometry_msgs.msg import Pose
from unique_identifier_msgs.msg import UUID


class Bridge(Node):
    def __init__(self):
        super().__init__("carla_objects_bridge")
        self.set_parameters([Parameter("use_sim_time", Parameter.Type.BOOL, True)])
        self.pub = self.create_publisher(
            PredictedObjects, "/perception/object_recognition/objects", 1)
        self.cl = None
        self.mod = None
        self.create_timer(0.1, self.tick)   # 10 Hz
        self.get_logger().info("carla_objects_bridge: CARLA actors -> Autoware objects")

    def _carla(self):
        try:
            import carla
            if self.cl is None:
                self.cl = carla.Client("localhost", 2000)
                self.cl.set_timeout(5.0)
                self.mod = carla
            w = self.cl.get_world()
            try:
                w.wait_for_tick(1.0)   # sync mode: actor snapshot needs a tick
            except Exception:
                pass
            return w
        except Exception as e:
            self.get_logger().warn(f"carla connect: {e}")
            return None

    def tick(self):
        w = self._carla()
        msg = PredictedObjects()
        msg.header.frame_id = "map"
        msg.header.stamp = self.get_clock().now().to_msg()
        if w is not None:
            actors = list(w.get_actors().filter("vehicle.*")) + \
                     list(w.get_actors().filter("walker.*"))
            for a in actors:
                if a.attributes.get("role_name") in ("ego_vehicle", "hero", "ego"):
                    continue
                msg.objects.append(self._to_obj(a))
        self.pub.publish(msg)

    def _to_obj(self, a):
        o = PredictedObject()
        # stable id from CARLA actor id
        u = UUID()
        u.uuid = [(a.id >> (8 * i)) & 0xFF for i in range(16)]
        o.object_id = u
        o.existence_probability = 0.95
        cls = ObjectClassification()
        cls.label = (ObjectClassification.PEDESTRIAN if a.type_id.startswith("walker")
                     else ObjectClassification.CAR)
        cls.probability = 1.0
        o.classification.append(cls)
        tf = a.get_transform()
        vel = a.get_velocity()
        k = PredictedObjectKinematics()
        p = Pose()
        p.position.x = tf.location.x
        p.position.y = -tf.location.y           # CARLA -> Autoware y-flip
        p.position.z = tf.location.z
        yaw = -math.radians(tf.rotation.yaw)    # yaw flip
        p.orientation.z = math.sin(yaw / 2)
        p.orientation.w = math.cos(yaw / 2)
        k.initial_pose_with_covariance.pose = p
        k.initial_twist_with_covariance.twist.linear.x = math.hypot(vel.x, vel.y)
        # a short straight predicted path so the planner can reason about it
        pp = PredictedPath()
        pp.confidence = 1.0
        pp.time_step.sec = 1
        for i in range(3):
            fp = Pose()
            fp.position.x = p.position.x + math.cos(yaw) * k.initial_twist_with_covariance.twist.linear.x * i
            fp.position.y = p.position.y + math.sin(yaw) * k.initial_twist_with_covariance.twist.linear.x * i
            fp.orientation = p.orientation
            pp.path.append(fp)
        k.predicted_paths.append(pp)
        o.kinematics = k
        bb = a.bounding_box.extent
        s = Shape()
        s.type = Shape.BOUNDING_BOX
        s.dimensions.x = max(0.5, bb.x * 2)
        s.dimensions.y = max(0.5, bb.y * 2)
        s.dimensions.z = max(0.5, bb.z * 2)
        o.shape = s
        return o


def main():
    rclpy.init()
    rclpy.spin(Bridge())


if __name__ == "__main__":
    main()
