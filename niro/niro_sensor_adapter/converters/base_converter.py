#!/usr/bin/env python3
"""Base converter contract for the niro sensor adapter.

A *converter* adapts a single raw sensor/driver message into the *standard*
message type that the niro pipeline expects on its canonical sensor topics.

Contract
--------
- INPUT  : one raw driver message (whatever the upstream vehicle/driver
           publishes). The concrete type is converter-specific.
- OUTPUT : one standard ROS message the niro pipeline already understands, or
           a small normalized Python value (e.g. a float speed) when the
           pipeline consumes a scalar rather than a message.
- Converters are PURE per-message functions: no I/O, no ROS publishing. The
  surrounding adapter node owns subscriptions/publishers and simply calls
  ``convert(msg)`` for each incoming message.

Standard target message types the niro pipeline expects
-------------------------------------------------------
- LiDAR    : ``sensor_msgs/msg/PointCloud2``
- GNSS     : ``sensor_msgs/msg/NavSatFix``
- IMU      : ``sensor_msgs/msg/Imu``
- Velocity : normalized longitudinal speed in m/s (derived from
             ``geometry_msgs/msg/TwistStamped`` or ``nav_msgs/msg/Odometry``)

Notes
-----
Message types are imported lazily *inside* methods (not at module import) so
this module compiles and imports cleanly in a non-ROS environment.
"""


class BaseConverter:
    """Abstract-ish base for all sensor converters.

    Subclasses override :meth:`convert`. ``params`` is an optional dict of
    per-converter configuration (e.g. frame remaps, unit overrides).
    """

    def __init__(self, params=None):
        self.params = params or {}

    def convert(self, msg):
        """Convert one raw driver ``msg`` to the standard output.

        Must be overridden by subclasses.
        """
        raise NotImplementedError(
            "BaseConverter.convert must be implemented by a subclass")
