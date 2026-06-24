#!/usr/bin/env python3
"""NavSatFix converter.

Supported GNSS type: ``sensor_msgs/msg/NavSatFix``.

PASSTHROUGH: the niro pipeline consumes ``NavSatFix`` directly, so the standard
output equals the input. frame_id / stamp normalization would go in
:meth:`convert` (driven by ``self.params``), left as a no-op for now.
"""
from .base_converter import BaseConverter


class NavSatFixConverter(BaseConverter):
    """Passthrough converter for sensor_msgs/msg/NavSatFix."""

    def convert(self, msg):
        # Passthrough. Insert frame_id/stamp normalization here if needed.
        return msg
