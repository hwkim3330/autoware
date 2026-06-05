# Building carla-ros-bridge on ROS 2 Jazzy (Ubuntu 24.04)

`carla-ros-bridge` officially targets ROS 2 Foxy/Humble. It builds on **Jazzy /
Ubuntu 24.04 / Python 3.12** with two small patches (Jazzy moved some headers).

## 1. Prerequisites

```bash
sudo apt-get install -y \
  python3-colcon-common-extensions python3-rosdep python3-vcstool git \
  ros-jazzy-ackermann-msgs ros-jazzy-derived-object-msgs ros-jazzy-cv-bridge \
  ros-jazzy-tf2-eigen ros-jazzy-pcl-conversions ros-jazzy-pcl-ros libpcl-dev \
  ros-jazzy-rviz-common ros-jazzy-rviz-ogre-vendor ros-jazzy-pluginlib
pip3 install --break-system-packages transforms3d
# CARLA python API matching the server (0.9.16 ships a cp312 wheel):
pip3 install --break-system-packages carla==0.9.16
```

## 2. Get the source

```bash
mkdir -p ~/carla-ros-ws/src && cd ~/carla-ros-ws/src
git clone --recurse-submodules https://github.com/carla-simulator/ros-bridge.git
```

## 3. Jazzy compatibility patches

**a. `pcl_recorder/include/PclRecorderROS2.h`** — header was renamed:
```diff
-#include <tf2_eigen/tf2_eigen.h>
+#include <tf2_eigen/tf2_eigen.hpp>
```

**b. `pcl_recorder/CMakeLists.txt`** — `tf2_eigen` is found but not propagated,
so its include dir is missing; add it to the target deps:
```diff
   ament_target_dependencies(${PROJECT_NAME}_node rclcpp sensor_msgs
-                            pcl_conversions tf2 tf2_ros)
+                            pcl_conversions tf2 tf2_ros tf2_eigen)
```

**c. CARLA version gate** — the bridge hard-requires the version in
`carla_ros_bridge/src/carla_ros_bridge/CARLA_VERSION`. Set it to your server
version so it doesn't refuse to start:
```bash
echo 0.9.16 > ~/carla-ros-ws/src/ros-bridge/carla_ros_bridge/src/carla_ros_bridge/CARLA_VERSION
```

## 4. Build

```bash
cd ~/carla-ros-ws
source /opt/ros/jazzy/setup.bash
export PIP_BREAK_SYSTEM_PACKAGES=1
colcon build --symlink-install
```

All 18 packages build. Verify:
```bash
source install/setup.bash
ros2 pkg executables carla_ros_bridge   # -> carla_ros_bridge bridge
```

## 5. Run

Start CARLA first (`scripts/start_carla.sh`), then `scripts/start_bridge.sh`.
Topics appear under `/carla/...`.
