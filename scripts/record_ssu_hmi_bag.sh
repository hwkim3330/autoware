#!/usr/bin/env bash
# record_ssu_hmi_bag.sh
#
# Record a SMALL HMI-oriented rosbag from the SSU vehicle. By design this does
# NOT record PointCloud2 or raw camera topics — only the lightweight state the
# read-only HMI gateway consumes (pose/twist, multimode, faults, trajectory,
# operation/route/mrm, vehicle velocity/steering, TF).
#
# Only topics that ACTUALLY EXIST (per `ros2 topic list`) are recorded; a
# missing candidate is skipped, not fatal. If none exist, warn and exit 0.
#
# Usage:
#   scripts/record_ssu_hmi_bag.sh [duration_seconds]
#     duration_seconds  optional; if given, record for that long then stop.

set -u

DURATION="${1:-}"

if ! command -v ros2 >/dev/null 2>&1; then
  echo "[record] WARN: ros2 not found; nothing to record." >&2
  exit 0
fi

# Candidate (lightweight) HMI topics — NO PointCloud2 / camera raw.
CANDIDATES=(
  /tf
  /tf_static
  # final fused localization (real-vehicle multimode)
  /localization/multimode/pose_with_covariance
  /localization/multimode/twist_with_covariance
  # per-source localization pose/twist (if exposed)
  /localization/lidar/pose_with_covariance
  /localization/lidar/twist_with_covariance
  /localization/gnss/pose_with_covariance
  /localization/gnss/twist_with_covariance
  # multimode state + transitions
  /multimode/mode
  /multimode/status
  /multimode/transition_event
  /multimode/transition_status
  # fault adaptation
  /adaptation/lidar_fault
  /adaptation/lidar_fault_status
  # planning / autoware api
  /planning/scenario_planning/trajectory
  /api/operation_mode/state
  /api/routing/state
  /api/fail_safe/mrm_state
  # vehicle status
  /vehicle/status/velocity_status
  /vehicle/status/steering_status
)

echo "[record] querying live topics..."
LIVE="$(ros2 topic list 2>/dev/null || true)"
if [ -z "$LIVE" ]; then
  echo "[record] WARN: 'ros2 topic list' returned nothing; is the system up?" >&2
  exit 0
fi

EXISTING=()
for t in "${CANDIDATES[@]}"; do
  if printf '%s\n' "$LIVE" | grep -Fxq "$t"; then
    EXISTING+=("$t")
  else
    echo "[record]   skip (absent): $t"
  fi
done

if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "[record] WARN: none of the candidate HMI topics exist; nothing to record." >&2
  exit 0
fi

OUT="ssu_hmi_bag_$(date +%Y%m%d_%H%M%S)"
echo "[record] recording ${#EXISTING[@]} topic(s) -> ${OUT}"
printf '[record]   + %s\n' "${EXISTING[@]}"

if [ -n "$DURATION" ]; then
  echo "[record] duration: ${DURATION}s"
  timeout "$DURATION" ros2 bag record -o "$OUT" "${EXISTING[@]}"
  rc=$?
  # timeout returns 124 on expiry — that is a normal stop, not an error.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
    echo "[record] done (${OUT})."
    exit 0
  fi
  echo "[record] bag record exited with code ${rc}" >&2
  exit "$rc"
else
  echo "[record] recording until Ctrl-C ..."
  ros2 bag record -o "$OUT" "${EXISTING[@]}"
fi
