#!/usr/bin/env python3
"""Velocity converter.

Normalizes a vehicle velocity message into a single longitudinal speed (m/s),
which is what the niro pipeline consumes for velocity.

Accepted INPUT types (auto-detected by attribute shape):
- ``geometry_msgs/msg/TwistStamped`` : speed taken from ``twist.linear``
- ``nav_msgs/msg/Odometry``          : speed taken from ``twist.twist.linear``

OUTPUT: a float longitudinal speed in m/s. Longitudinal speed is taken as the
linear-x component when available; ``magnitude=True`` in ``params`` switches to
the planar magnitude ``hypot(x, y)`` instead.
"""
import math

from .base_converter import BaseConverter


class VelocityConverter(BaseConverter):
    """Convert TwistStamped or Odometry to a normalized longitudinal speed."""

    def convert(self, msg):
        twist = self._extract_twist(msg)
        if twist is None:
            raise TypeError(
                "VelocityConverter expects geometry_msgs/TwistStamped or "
                "nav_msgs/Odometry, got: %r" % type(msg))
        lin = twist.linear
        if self.params.get("magnitude"):
            return math.hypot(lin.x, lin.y)
        return float(lin.x)

    @staticmethod
    def _extract_twist(msg):
        # nav_msgs/Odometry -> msg.twist.twist.linear
        twist = getattr(msg, "twist", None)
        if twist is None:
            return None
        inner = getattr(twist, "twist", None)
        if inner is not None and hasattr(inner, "linear"):
            return inner            # Odometry
        if hasattr(twist, "linear"):
            return twist            # TwistStamped
        return None
