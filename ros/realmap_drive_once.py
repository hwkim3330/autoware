#!/usr/bin/env python3
"""One clean real-map drive: STOP+clear -> seed start -> route -> engage -> watch.
Run in the autoware container: python3 realmap_drive_once.py <sx> <sy> <syaw> <gx> <gy> <gyaw>
Defaults to the proven pangyo_crd start/goal."""
import math, subprocess, sys, time

def ros(a, t=30):
    return subprocess.run(
        ["bash", "-lc",
         "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; " + a],
        capture_output=True, text=True, timeout=t)

def q(yaw):
    return math.sin(math.radians(yaw)/2), math.cos(math.radians(yaw)/2)

a = sys.argv[1:]
sx, sy, syaw = (float(a[0]), float(a[1]), float(a[2])) if len(a) >= 3 else (507.42, -476.24, 89.26)
gx, gy, gyaw = (float(a[3]), float(a[4]), float(a[5])) if len(a) >= 6 else (314.10, -445.04, 141.57)

ros("ros2 service call /api/operation_mode/change_to_stop autoware_adapi_v1_msgs/srv/ChangeOperationMode '{}'", 20)
ros("ros2 service call /api/routing/clear_route autoware_adapi_v1_msgs/srv/ClearRoute '{}'", 20)
time.sleep(2)
sz, sw = q(syaw)
ros(f"ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped "
    f"'{{header: {{frame_id: map}}, pose: {{pose: {{position: {{x: {sx}, y: {sy}, z: 0.0}}, "
    f"orientation: {{z: {sz}, w: {sw}}}}}, covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, "
    f"0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.068]}}}}'", 20)
print("seeded; settling", flush=True); time.sleep(12)
gz, gw = q(gyaw)
r = ros(f"ros2 service call /api/routing/set_route_points autoware_adapi_v1_msgs/srv/SetRoutePoints "
        f"'{{header: {{frame_id: map}}, goal: {{position: {{x: {gx}, y: {gy}, z: 0.0}}, "
        f"orientation: {{z: {gz}, w: {gw}}}}}}}'", 40)
print("set_route:", (r.stdout or r.stderr).strip().splitlines()[-1], flush=True)
for _ in range(18):
    av = ros("ros2 topic echo --once --field is_autonomous_mode_available /api/operation_mode/state", 6)
    if "true" in av.stdout.lower():
        e = ros("ros2 service call /api/operation_mode/change_to_autonomous autoware_adapi_v1_msgs/srv/ChangeOperationMode '{}'", 15)
        print("engage:", (e.stdout or "").strip().splitlines()[-1], flush=True); break
    time.sleep(2)
for i in range(10):
    s = ros("ros2 topic echo --once --field twist.twist.linear.x /localization/kinematic_state", 6)
    v = s.stdout.strip().splitlines()[0] if s.stdout.strip() else "?"
    print(f"speed_x={v} m/s", flush=True); time.sleep(2.5)
