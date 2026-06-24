#!/usr/bin/env python3
"""
GenericAutowareAdapter — minimal read-only adapter for a neutral Autoware
deployment. Subscribes only the non-empty topics in the generic profile
(/multimode/mode and /multimode/status as std_msgs/String). Empty topics are
warned+skipped by the base adapter.
"""
from std_msgs.msg import String

from base_adapter import BaseAdapter  # noqa: F401


class GenericAutowareAdapter(BaseAdapter):
    def subscribe(self):
        s = self.state

        def _on_mode(msg):
            s.localization_mode = self.parse_string(msg) or "UNKNOWN"

        self._sub("multimode.mode_topic",
                  self._topic("multimode", "mode_topic"), String, _on_mode)

        def _on_status(msg):
            self.apply_multimode_status_json(self.parse_json_string(msg))

        self._sub("multimode.status_topic",
                  self._topic("multimode", "status_topic"), String, _on_status)
