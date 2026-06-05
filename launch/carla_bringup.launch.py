#!/usr/bin/env python3
"""Top-level bringup: carla-ros-bridge + ego vehicle (lite sensor set).

Assumes a CARLA server is already running on :2000
(start it with scripts/start_carla.sh — software/lavapipe on a no-GPU box).

Usage:
  ros2 launch <this dir>/carla_bringup.launch.py
  ros2 launch <this dir>/carla_bringup.launch.py town:=Town01 objects:=/abs/path/objects_lite.json
"""
import os
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from ament_index_python.packages import get_package_share_directory

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OBJECTS = os.path.normpath(os.path.join(THIS_DIR, "..", "ros", "objects_lite.json"))


def generate_launch_description():
    bridge_share = get_package_share_directory("carla_ros_bridge")
    spawn_share = get_package_share_directory("carla_spawn_objects")

    host = LaunchConfiguration("host")
    port = LaunchConfiguration("port")
    town = LaunchConfiguration("town")
    objects = LaunchConfiguration("objects")

    return LaunchDescription([
        DeclareLaunchArgument("host", default_value="localhost"),
        DeclareLaunchArgument("port", default_value="2000"),
        DeclareLaunchArgument("town", default_value="Town01"),
        DeclareLaunchArgument("objects", default_value=DEFAULT_OBJECTS),

        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(bridge_share, "carla_ros_bridge.launch.py")),
            launch_arguments={
                "host": host, "port": port, "town": town,
                "timeout": "120", "synchronous_mode": "True",
                "fixed_delta_seconds": "0.1",  # 10Hz sim step; CPU rendering is slow
            }.items(),
        ),

        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(spawn_share, "carla_spawn_objects.launch.py")),
            launch_arguments={"objects_definition_file": objects}.items(),
        ),
    ])
