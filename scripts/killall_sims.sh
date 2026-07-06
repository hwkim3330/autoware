#!/usr/bin/env bash
# Stop EVERY simulator + Autoware stack cleanly to free the box (GPU/CPU).
# Covers: AWSIM (host Unity), CARLA (host), Autoware/e2e/planning_sim + all
# gateways/helpers (container), host watcher loops. Safe to run anytime.
#   ./run.sh killall        (or: bash scripts/killall_sims.sh)
set +e
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }

echo "==> killing host simulators (AWSIM, CARLA)"
SUDO pkill -9 -f AWSIM-Demo.x86_64 2>/dev/null
SUDO pkill -9 -f CarlaUE4-Linux-Shipping 2>/dev/null

echo "==> killing host watcher/flow loops"
pkill -9 -f "run_real_map_sim.sh|run_localization_demo.sh|run_osm_demo.sh|map_switch_daemon.sh|_flow.sh|_test.sh|post_reload.sh" 2>/dev/null

KILL_CONTAINER_PROCS() {
  SUDO docker exec autoware bash -c '
    pkill -9 -f e2e_simulator;            pkill -9 -f planning_simulator
    pkill -9 -f component_container;      pkill -9 -f autoware
    pkill -9 -f ros_ws_gateway;           pkill -9 -f niro_hmi_gateway
    pkill -9 -f auto_realmap_drive;       pkill -9 -f virtual_lidar
    pkill -9 -f multimode_supervisor;     pkill -9 -f niro_bridge
    pkill -9 -f drive_monitor;            pkill -9 -f patrol_loop
    pkill -9 -f rviz2;                    pkill -9 -f gnss_only_localizer
    pkill -9 -f cloud_relay;              pkill -9 -f perception_stub
    pkill -9 -f roii_lidar_health_monitor; pkill -9 -f roii_fault
    pkill -9 -f roii_reconfig;            pkill -9 -f roii_gnss
    pkill -9 -f roii_watchdog;            pkill -9 -f fastdds
    exit 0' 2>/dev/null
}

# BUG (found 2026-07-06): a single pkill sweep only catches whatever component
# containers exist AT THAT INSTANT. `ros2 launch` composable-node containers
# keep spawning for 30-60s after the top-level launch process starts, and once
# spawned they are NOT children of that launch process (killing it does not
# cascade-kill them) -- so a sweep run while a launch is still mid-startup
# reports "done" while leaving a dozen+ live component_containers running,
# silently burning CPU/GPU. Verified live: killall reported clean, but
# `ps aux` a moment later still showed map_container/ndt_scan_matcher/
# autoware_carla_interface/etc. actively accumulating CPU time.
# Fix: verify what actually killed the pattern-match is supposed to catch
# (not just ports + sim binaries), retry the sweep a few times, and fall back
# to a full container stop/start (the documented-safe way, NEVER `restart` --
# that breaks CUDA/NVML) if anything survives 3 sweeps.
echo "==> killing container Autoware + sims + gateways"
for i in 1 2 3; do
  KILL_CONTAINER_PROCS
  sleep 2
  remaining=$(docker exec autoware bash -c \
    'pgrep -fc "component_container|autoware_|ndt_scan_matcher|map_hash_generator|ros_ws_gateway|rviz2"' 2>/dev/null)
  [ -z "$remaining" ] && remaining=0
  [ "$remaining" -eq 0 ] && break
  echo "    sweep $i: $remaining Autoware process(es) still alive, retrying..."
done

if [ "${remaining:-0}" -gt 0 ]; then
  echo "    pkill sweeps didn't fully clear it -- falling back to container stop/start"
  echo "    (NOT 'restart': that breaks CUDA/NVML on this box)"
  SUDO docker stop autoware >/dev/null
  SUDO docker start autoware >/dev/null
  sleep 8
fi

echo "==> remaining (should be empty):"
ss -tlnp 2>/dev/null | grep -E ':(2000|8765|8766)' && echo "  (a sim port still open)" || echo "  ports 2000/8765/8766 clear"
pgrep -f "AWSIM-Demo|CarlaUE4-Linux-Shipping" >/dev/null && echo "  host sim still up" || echo "  host sims down"
lingering=$(docker exec autoware bash -c \
  'pgrep -fc "component_container|autoware_|ndt_scan_matcher"' 2>/dev/null)
[ -z "$lingering" ] && lingering=0
[ "$lingering" -eq 0 ] && echo "  container Autoware nodes: clear" || echo "  WARNING: $lingering Autoware node(s) still alive in container"
echo "==> GPU now:"
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null
echo "done. (the 'autoware' container itself stays up; only the stacks inside are stopped)"
