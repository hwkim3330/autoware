#!/bin/bash
# ROii 4-LiDAR verification: topics, hz, stamps, TF, concat, localization,
# health/diagnostics, RViz plugin build/registration.
SUDO() { timeout 120 sudo -S "$@" < <(echo 1); }
IN() { SUDO docker exec autoware bash -lc "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash 2>/dev/null; source /opt/roii_ws/install/setup.bash 2>/dev/null; $1" 2>/dev/null; }

echo "================ ROii 4-LiDAR check ================"
for s in front_g32 rear_g32 left_pandar right_pandar; do
  T=/sensing/lidar/$s/pointcloud_before_sync
  echo "--- $s ---"
  IN "ros2 topic list | grep -q $T && echo '  topic   : OK' || echo '  topic   : MISSING'"
  echo -n "  hz      : "; IN "timeout 5 ros2 topic hz $T 2>/dev/null | grep -m1 average | awk '{print \$3}'" || echo "-"
  echo -n "  stampΔ  : "; IN "timeout 5 python3 -c \"
import rclpy, time
from rclpy.node import Node
from rclpy.parameter import Parameter
from sensor_msgs.msg import PointCloud2
from rclpy.qos import QoSProfile, ReliabilityPolicy
rclpy.init(); n=Node('chk'); n.set_parameters([Parameter('use_sim_time',Parameter.Type.BOOL,True)])
box={}
qos=QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT)
n.create_subscription(PointCloud2,'$T',lambda m: box.update(s=m.header.stamp.sec+m.header.stamp.nanosec*1e-9),qos)
t=time.time()
while 's' not in box and time.time()-t<4: rclpy.spin_once(n,timeout_sec=0.2)
now=n.get_clock().now().nanoseconds*1e-9
print(f'{abs(now-box[\\\"s\\\"]):.3f}s' if 's' in box else 'no-data')\""
  echo -n "  TF      : "; IN "timeout 5 ros2 run tf2_ros tf2_echo base_link roii_$s 2>/dev/null | grep -m1 -c Translation && echo OK || echo MISSING" | tail -1
done
echo "--- pipeline ---"
echo -n "  concat hz     : "; IN "timeout 6 ros2 topic hz /sensing/lidar/concatenated/pointcloud 2>/dev/null | grep -m1 average | awk '{print \$3}'" || echo "-"
echo -n "  kinematic hz  : "; IN "timeout 6 ros2 topic hz /localization/kinematic_state 2>/dev/null | grep -m1 average | awk '{print \$3}'" || echo "-"
echo "--- health / diagnostics ---"
echo -n "  lidar_health  : "; IN "timeout 4 ros2 topic echo /roii/lidar_health --once --field data 2>/dev/null | head -c 120"; echo
echo -n "  diagnostics   : "; IN "timeout 4 ros2 topic echo /diagnostics --once 2>/dev/null | grep -m1 -c roii_lidar && echo OK || echo MISSING" | tail -1
echo "--- RViz plugin ---"
IN "ls /opt/roii_ws/install/roii_sensor_fault_panel/lib/libroii_sensor_fault_panel.so >/dev/null 2>&1 && echo '  library : OK' || echo '  library : NOT BUILT'"
IN "grep -q ROiiSensorFaultPanel /opt/roii_ws/install/roii_sensor_fault_panel/share/roii_sensor_fault_panel/plugin_description.xml 2>/dev/null && echo '  plugin  : registered' || echo '  plugin  : NOT registered'"
echo "===================================================="
