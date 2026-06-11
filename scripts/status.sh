#!/bin/bash
# One-glance status of the whole stack — run this before starting anything
# to avoid conflicting processes. (사용: bash scripts/status.sh)
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }

echo "================ ROii Autoware stack status ================"
echo "--- CARLA ---"
if pgrep -f CarlaUE4-Linux-Shipping >/dev/null; then
  echo "  process : UP (pid $(pgrep -f CarlaUE4-Linux-Shipping | head -1), cores $(taskset -cp $(pgrep -f CarlaUE4-Linux-Shipping | head -1) 2>/dev/null | awk '{print $NF}'))"
else
  echo "  process : DOWN"
fi
ss -tlnp 2>/dev/null | grep -q :2000 && echo "  rpc:2000: LISTENING" || echo "  rpc:2000: not listening (booting or dead)"
grep -q "Signal=11" /tmp/carla.log 2>/dev/null && echo "  log     : crashed earlier (Signal 11) -- $(grep -c 'Signal=11' /tmp/carla.log)x"

echo "--- Autoware container ---"
ST=$(SUDO docker inspect autoware --format '{{.State.Status}} cpuset={{.HostConfig.CpusetCpus}}')
echo "  $ST"
E2E=$(SUDO docker exec autoware bash -lc "pgrep -fc e2e_simulator || true")
GW=$(SUDO docker exec autoware bash -lc "pgrep -fc ros_ws_gateway || true")
PS=$(SUDO docker exec autoware bash -lc "pgrep -fc perception_stub || true")
RV=$(SUDO docker exec autoware bash -lc "pgrep -fc rviz2 || true")
NN=$(SUDO docker exec autoware bash -lc "pgrep -fc component_container || true")
echo "  e2e launch: ${E2E:-0}   ros nodes(containers): ${NN:-0}   gateway: ${GW:-0}   pstub: ${PS:-0}   rviz: ${RV:-0}"

echo "--- host helpers ---"
pgrep -af "run_localization_demo|test_all_towns|gen_spawn_table" | sed 's/^/  /' || echo "  (none)"
echo "--- tablet ---"
command -v adb >/dev/null && adb devices | sed -n '2p' | sed 's/^/  /'
echo "--- load ---"
echo "  $(cut -d' ' -f1-3 /proc/loadavg) (16 cores)"
echo "============================================================"
