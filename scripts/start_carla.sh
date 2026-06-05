#!/bin/bash
# Start CARLA 0.9.16 server on a machine WITHOUT an NVIDIA GPU
# (Intel UHD 630 / no discrete GPU). Forces lavapipe (llvmpipe) software
# Vulkan so UE4.26 does not crash with "Out of Local Memory MemTypeIndex=1"
# on the iGPU's tiny device-local heap.
#
# Requirements (one-time):
#   - CARLA installed at $CARLA_ROOT (default /opt/carla-simulator)
#   - mesa-vulkan-drivers (provides lavapipe ICD lvp_icd.x86_64.json)
#   - plenty of swap (CPU rendering uses >16GB): see scripts/setup_swap.sh
#
# Usage: ./start_carla.sh [rpc_port]
set -e

CARLA_ROOT="${CARLA_ROOT:-/opt/carla-simulator}"
RPC_PORT="${1:-2000}"
BIN="$CARLA_ROOT/CarlaUE4/Binaries/Linux/CarlaUE4-Linux-Shipping"

if [ ! -x "$BIN" ]; then
  echo "CARLA binary not found at $BIN"
  echo "Set CARLA_ROOT or install CARLA 0.9.16 first."
  exit 1
fi

# Force software Vulkan (lavapipe) as the ONLY physical device.
# BOTH variables are required — VK_ICD_FILENAMES alone still lets the
# loader enumerate the Intel iGPU, which UE4 then picks and crashes on.
LVP_ICD=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
export VK_ICD_FILENAMES="$LVP_ICD"
export VK_DRIVER_FILES="$LVP_ICD"
export VK_LOADER_LAYERS_DISABLE=VK_LAYER_NV_optimus

echo "Starting CARLA (software/lavapipe) on port $RPC_PORT ..."
echo "First launch compiles shaders on CPU — get_world() may take a few minutes."
cd "$CARLA_ROOT/CarlaUE4/Binaries/Linux"
exec ./CarlaUE4-Linux-Shipping CarlaUE4 \
  -RenderOffScreen -quality-level=Low -nosound -carla-rpc-port="$RPC_PORT"
