#!/usr/bin/env python3
"""Niro multimode localization core (이중측위 융합 + 결함/모드).

Brings up the dual-localization fusion layer:
  - niro_pose_merger      : LiDAR+GNSS pose/twist fusion by per-mode weights
  - niro_mode_manager     : normal <-> lidar_fault arbitration
  - niro_lidar_fault_adapter : E/E fault state -> normalized fault signal

It does NOT bring up the two localization pipelines themselves (NDT / gnss_poser)
or the sensor drivers — those are separate launches (niro_lidar_localization,
niro_gnss_localization, niro_sensor_adapter). This is the fusion brain on top.
"""
import os
from launch import LaunchDescription
from launch_ros.actions import Node

NIRO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = os.path.join(NIRO, "config")
MM = os.path.join(NIRO, "niro_multimode_localization")
MGR = os.path.join(NIRO, "niro_mode_manager")


def generate_launch_description():
    return LaunchDescription([
        Node(
            executable="python3", name="niro_pose_merger", output="screen",
            arguments=[os.path.join(MM, "pose_merger_node.py")],
            parameters=[os.path.join(CFG, "pose_merger.yaml")],
        ),
        Node(
            executable="python3", name="niro_mode_manager", output="screen",
            arguments=[os.path.join(MGR, "mode_manager_node.py")],
            parameters=[os.path.join(CFG, "mode_policy.yaml")],
        ),
        Node(
            executable="python3", name="niro_lidar_fault_adapter", output="screen",
            arguments=[os.path.join(MM, "lidar_fault_adapter_node.py")],
        ),
    ])
