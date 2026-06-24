#!/usr/bin/env bash
# collect_ssu_ros_environment.sh
#
# Snapshot the SSU vehicle's ROS2 environment into a timestamped directory and
# tar it for offline analysis (used to fill config/hmi/ssu_niro.yaml and the
# converters). Best-effort throughout: a missing command or a single failing
# topic must NOT abort the whole collection.
#
# Usage:
#   scripts/collect_ssu_ros_environment.sh [label]
#     label  optional tag for the output dir (default: "snapshot")
#
# Output:
#   ssu_ros_env_<label>/        (directory)
#   ssu_ros_env_<label>.tar.gz  (archive)

set -u  # NOTE: intentionally NOT 'set -e' — collection is best-effort.

LABEL="${1:-snapshot}"
OUT="ssu_ros_env_${LABEL}"
mkdir -p "$OUT"

echo "[collect] writing to ${OUT}/"

# Keywords used to flag "interesting" topics into a filtered list.
KEYWORDS="localization|lidar|gnss|pose|twist|multimode|fault|trajectory|operation|route|mrm|vehicle|velocity|steering"

run() {
  # run <outfile> <description> <command...>
  local outfile="$1"; shift
  local desc="$1"; shift
  echo "[collect] ${desc}"
  {
    echo "### ${desc}"
    echo "### \$ $*"
    echo
    "$@" 2>&1
  } >"${OUT}/${outfile}" || true
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- basic environment -------------------------------------------------------
{
  echo "### ROS_DISTRO"
  echo "${ROS_DISTRO:-<unset>}"
} >"${OUT}/ros_distro.txt" || true

if have ros2; then
  run ros2_doctor.txt       "ros2 doctor --report"   ros2 doctor --report
  run topic_list.txt        "ros2 topic list -t"     ros2 topic list -t
  run node_list.txt         "ros2 node list"         ros2 node list
  run service_list.txt      "ros2 service list -t"   ros2 service list -t
  run action_list.txt       "ros2 action list -t"    ros2 action list -t
  run pkg_list.txt          "ros2 pkg list"          ros2 pkg list
else
  echo "[collect] WARN: ros2 not found; skipping ros2 queries" \
    | tee "${OUT}/WARNINGS.txt"
fi

# --- filter interesting topics ----------------------------------------------
# topic_list.txt lines look like:  /topic/name [pkg/msg/Type]
MATCHED="${OUT}/matched_topics.txt"
: >"$MATCHED"
if [ -f "${OUT}/topic_list.txt" ]; then
  grep -Ei "$KEYWORDS" "${OUT}/topic_list.txt" >"$MATCHED" 2>/dev/null || true
fi

# --- per-matched-topic detail ------------------------------------------------
if have ros2 && [ -s "$MATCHED" ]; then
  TOPIC_INFO="${OUT}/topic_info"
  IFACE_DIR="${OUT}/interfaces"
  mkdir -p "$TOPIC_INFO" "$IFACE_DIR"
  echo "[collect] inspecting matched topics"
  # Read raw lines (each: "<topic> [<type>]") and inspect each best-effort.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    topic="$(printf '%s\n' "$line" | awk '{print $1}')"
    # type is inside [ ... ] if present
    type="$(printf '%s\n' "$line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
    [ -z "$topic" ] && continue
    safe="$(printf '%s' "$topic" | tr '/ ' '__')"
    {
      echo "### ros2 topic info -v ${topic}"
      ros2 topic info -v "$topic" 2>&1
    } >"${TOPIC_INFO}/${safe}.txt" || true
    if [ -n "$type" ] && [ ! -f "${IFACE_DIR}/$(printf '%s' "$type" | tr '/ ' '__').txt" ]; then
      {
        echo "### ros2 interface show ${type}"
        ros2 interface show "$type" 2>&1
      } >"${IFACE_DIR}/$(printf '%s' "$type" | tr '/ ' '__').txt" || true
    fi
  done <"$MATCHED"
fi

# --- TF frames ---------------------------------------------------------------
if have ros2; then
  echo "[collect] capturing TF frames (best-effort)"
  (
    cd "$OUT" || exit 0
    timeout 10 ros2 run tf2_tools view_frames >view_frames.log 2>&1 || true
  ) || true
fi

# --- archive -----------------------------------------------------------------
TARBALL="${OUT}.tar.gz"
if have tar; then
  tar czf "$TARBALL" "$OUT" 2>/dev/null \
    && echo "[collect] wrote ${TARBALL}" \
    || echo "[collect] WARN: tar failed"
else
  echo "[collect] WARN: tar not found; left directory ${OUT}/ uncompressed"
fi

echo "[collect] done."
exit 0
