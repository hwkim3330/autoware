# SSU HMI Rosbag Recording

Recording a small, HMI-focused rosbag from the SSU vehicle with
`scripts/record_ssu_hmi_bag.sh`.

## Usage

```bash
# Record until Ctrl-C
./scripts/record_ssu_hmi_bag.sh

# Record for a fixed duration (seconds), then stop
./scripts/record_ssu_hmi_bag.sh 60
```

Output: `ssu_hmi_bag_<YYYYmmdd_HHMMSS>/` in the current directory.

## What it records

The script keeps a candidate list of lightweight HMI/state topics and records
**only those that actually exist** on the live system (checked against
`ros2 topic list`). Candidates include:

- `/tf`, `/tf_static`
- multimode localization: `/localization/multimode/pose_with_covariance`,
  `/localization/multimode/twist_with_covariance`
- per-source localization pose/twist (lidar/gnss) if present
- multimode state: `/multimode/mode`, `/multimode/status`,
  `/multimode/transition_event`, `/multimode/transition_status`
- fault adaptation: `/adaptation/lidar_fault`, `/adaptation/lidar_fault_status`
- planning/api: trajectory, operation mode, route state, MRM state
- vehicle status: velocity, steering

Behavior:
- A missing candidate topic is **skipped** (logged), not fatal.
- If **none** of the candidates exist, the script warns and exits `0`.
- With a duration arg, a clean `timeout` expiry (exit 124) is treated as a
  normal stop.

## Why PointCloud2 / camera are excluded

The bag is meant for HMI/state replay and debugging, not perception
re-processing. Raw `sensor_msgs/msg/PointCloud2` and camera image topics are
high-bandwidth and would balloon the bag size (gigabytes/minute) while adding
nothing the read-only HMI gateway consumes. They are intentionally **not** in
the candidate list. Record those separately if perception data is needed.

## Replaying

```bash
ros2 bag play ssu_hmi_bag_<timestamp>

# Then point the gateway at the replayed topics:
./scripts/run_niro_hmi_gateway.sh ssu_niro
```

Because TF and the multimode/localization state are captured, replaying the bag
reproduces the HMI feed without the vehicle present. If the bag was recorded
with simulated/recorded time, run the gateway and players consistently (the
gateway broadcasts on wall-clock and does not depend on `/clock`).
