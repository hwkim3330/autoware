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

echo "==> killing container Autoware + sims + gateways"
SUDO docker exec autoware bash -c '
  pkill -9 -f e2e_simulator;            pkill -9 -f planning_simulator
  pkill -9 -f component_container;      pkill -9 -f autoware
  pkill -9 -f ros_ws_gateway;           pkill -9 -f niro_hmi_gateway
  pkill -9 -f auto_realmap_drive;       pkill -9 -f virtual_lidar
  pkill -9 -f multimode_supervisor;     pkill -9 -f niro_bridge
  pkill -9 -f drive_monitor;            pkill -9 -f patrol_loop
  pkill -9 -f rviz2;                    pkill -9 -f gnss_only_localizer
  exit 0' 2>/dev/null

sleep 2
echo "==> remaining (should be empty):"
ss -tlnp 2>/dev/null | grep -E ':(2000|8765|8766)' && echo "  (a sim port still open)" || echo "  ports 2000/8765/8766 clear"
pgrep -f "AWSIM-Demo|CarlaUE4-Linux-Shipping" >/dev/null && echo "  host sim still up" || echo "  host sims down"
echo "==> GPU now:"
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null
echo "done. (the 'autoware' container itself stays up; only the stacks inside are stopped)"
