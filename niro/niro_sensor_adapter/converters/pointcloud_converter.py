#!/usr/bin/env python3
"""PointCloud converter.

Default supported LiDAR type: ``sensor_msgs/msg/PointCloud2``.

This is a PASSTHROUGH: the niro pipeline already consumes ``PointCloud2``
directly, so the standard output equals the input. Any frame_id / stamp
normalization (e.g. remapping the driver frame to ``base_link`` or rewriting a
zero/driver stamp to the receive time) would go in :meth:`convert` below, driven
by ``self.params`` (e.g. ``params["frame_id"]``). It is intentionally left as a
no-op until a concrete remap requirement exists.
"""
from .base_converter import BaseConverter


class PointCloudConverter(BaseConverter):
    """Passthrough converter for sensor_msgs/msg/PointCloud2."""

    def convert(self, msg):
        # Passthrough. Insert frame_id/stamp normalization here if needed:
        #   if self.params.get("frame_id"):
        #       msg.header.frame_id = self.params["frame_id"]
        return msg
