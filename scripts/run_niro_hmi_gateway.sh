#!/usr/bin/env bash
# Launch the READ-ONLY Niro HMI gateway for a given profile.
#
#   ./scripts/run_niro_hmi_gateway.sh <profile>
#       profile = carla_niro | ssu_niro | generic_autoware   (default carla_niro)
#
# Does NOT touch ros/ros_ws_gateway.py (the CARLA control path). Read-only:
# subscribes ROS topics and streams JSON to Android clients.
set -u

PROFILE="${1:-carla_niro}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_DIR}/config/hmi/${PROFILE}.yaml"
GATEWAY="${REPO_DIR}/ros/niro_hmi_gateway.py"

case "${PROFILE}" in
  carla_niro|ssu_niro|generic_autoware) ;;
  *)
    echo "ERROR: unknown profile '${PROFILE}'"
    echo "       choices: carla_niro | ssu_niro | generic_autoware"
    exit 2 ;;
esac

# 1) ROS sourced?
if [ -z "${ROS_DISTRO:-}" ] && [ -z "${AMENT_PREFIX_PATH:-}" ]; then
  echo "WARN: ROS 2 does not appear to be sourced (no ROS_DISTRO/AMENT_PREFIX_PATH)."
  echo "      source /opt/ros/humble/setup.bash  (and your workspace) first."
fi

# 2) config exists?
if [ ! -f "${CONFIG}" ]; then
  echo "ERROR: config file not found: ${CONFIG}"
  exit 1
fi

# 3) python deps
MISSING=""
python3 -c "import websockets" 2>/dev/null || MISSING="${MISSING} websockets"
python3 -c "import yaml" 2>/dev/null || MISSING="${MISSING} pyyaml"
if [ -n "${MISSING}" ]; then
  echo "ERROR: missing python deps:${MISSING}"
  echo "       pip3 install --break-system-packages${MISSING}"
  exit 1
fi

# 4) port in use?
PORT="$(python3 -c "import yaml,sys; print((yaml.safe_load(open('${CONFIG}')).get('network') or {}).get('port', 8765))" 2>/dev/null || echo 8765)"
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
    echo "WARN: TCP port ${PORT} already appears to be LISTENing — another gateway?"
  fi
fi

echo "Starting Niro HMI gateway: profile=${PROFILE} port=${PORT} (read-only)"
exec python3 "${GATEWAY}" "${PROFILE}"
