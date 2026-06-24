#!/usr/bin/env python3
"""IMU converter.

Supported IMU type: ``sensor_msgs/msg/Imu``.

PASSTHROUGH: the niro pipeline consumes ``Imu`` directly, so the standard output
equals the input. frame_id / stamp normalization (and any axis/sign remap) would
go in :meth:`convert` (driven by ``self.params``), left as a no-op for now.
"""
from .base_converter import BaseConverter


class ImuConverter(BaseConverter):
    """Passthrough converter for sensor_msgs/msg/Imu."""

    def convert(self, msg):
        # Passthrough. Insert frame_id/stamp/axis normalization here if needed.
        return msg
