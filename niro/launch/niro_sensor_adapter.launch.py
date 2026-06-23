#!/usr/bin/env python3
"""Niro Virtual Sensor Driver — starts all four sensor adapters.

Each republishes a raw on-vehicle driver topic as the standard Autoware /sensing
topic. Override in_topic per role to match the real driver topics at integration.
"""
import os
from launch import LaunchDescription
from launch_ros.actions import Node

ADP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "niro_sensor_adapter", "sensor_adapter.py")


def _adapter(role):
    return Node(executable="python3", name=f"niro_{role}_adapter", output="screen",
                arguments=[ADP, role])


def generate_launch_description():
    return LaunchDescription([_adapter(r) for r in ("ouster", "gnss", "imu", "velocity")])
