#!/usr/bin/env python3
"""SSU custom-message converter — STUB ONLY.

Do NOT implement until the real SSU message definitions are received.

The SSU vehicle may publish custom (non-standard) message types for one or more
sensors. The exact field layout is currently UNKNOWN, so this converter is an
intentional stub: implementing it now would require guessing field names, which
is forbidden.

To fill this in once the definitions arrive:
  1. Capture the real type with::

         ros2 interface show <ssu_msg_type>

     (e.g. from scripts/collect_ssu_ros_environment.sh output).
  2. Lazily import the message type inside :meth:`convert`.
  3. Map its fields onto the matching standard output (PointCloud2 / NavSatFix /
     Imu / longitudinal speed) — see converters/base_converter.py for the list
     of standard target types.

No guessed field access appears below by design.
"""
from .base_converter import BaseConverter


class SsuCustomConverter(BaseConverter):
    """Stub for an SSU custom sensor message. Not yet implemented."""

    def convert(self, msg):
        raise NotImplementedError(
            "SSU custom message definition not yet provided")
