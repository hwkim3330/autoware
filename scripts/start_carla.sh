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
#
# Newer mesa ships lvp_icd.json with a RELATIVE library_path
# ("libvulkan_lvp.so"); inside CARLA's process the loader fails to resolve it
# ("Found no drivers"). So we synthesize an ICD manifest with the ABSOLUTE
# library path, which works regardless of mesa version.
LVP_LIB=$(ldconfig -p 2>/dev/null | awk '/libvulkan_lvp\.so/{print $NF; exit}')
[ -z "$LVP_LIB" ] && LVP_LIB=/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so
if [ ! -f "$LVP_LIB" ]; then
  echo "lavapipe library not found — install mesa-vulkan-drivers"
  exit 1
fi
SRC_ICD=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json 2>/dev/null | head -1)
APIVER=$(grep -oP '"api_version"\s*:\s*"\K[^"]+' "$SRC_ICD" 2>/dev/null)
[ -z "$APIVER" ] && APIVER="1.3.275"
LVP_ICD=$(mktemp /tmp/lvp_icd_abs.XXXX.json)
cat > "$LVP_ICD" <<JSON
{ "ICD": { "api_version": "$APIVER", "library_path": "$LVP_LIB" },
  "file_format_version": "1.0.1" }
JSON
export VK_ICD_FILENAMES="$LVP_ICD"
export VK_DRIVER_FILES="$LVP_ICD"
export VK_LOADER_LAYERS_DISABLE=VK_LAYER_NV_optimus

echo "Starting CARLA (software/lavapipe) on port $RPC_PORT ..."
echo "First launch compiles shaders on CPU — get_world() may take a few minutes."
cd "$CARLA_ROOT/CarlaUE4/Binaries/Linux"
exec ./CarlaUE4-Linux-Shipping CarlaUE4 \
  -RenderOffScreen -quality-level=Low -nosound -carla-rpc-port="$RPC_PORT"
