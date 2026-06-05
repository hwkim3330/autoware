#!/bin/bash
# CARLA software rendering (lavapipe) uses >16GB RAM. On a 16GB box this
# triggers systemd-oomd before the simulator finishes loading. This script
# adds a large swapfile and disables the aggressive OOM daemon.
# Run once with sudo.
set -e
SWAP=/swapfile-carla
SIZE_GB="${1:-32}"

if [ ! -f "$SWAP" ]; then
  echo "Creating ${SIZE_GB}G swapfile at $SWAP ..."
  fallocate -l "${SIZE_GB}G" "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count=$((SIZE_GB*1024)) status=progress
  chmod 600 "$SWAP"
  mkswap "$SWAP"
fi
swapon "$SWAP" 2>/dev/null || true

# systemd-oomd kills CARLA on memory pressure before it can load. Mask it.
systemctl stop systemd-oomd.socket systemd-oomd.service 2>/dev/null || true
systemctl mask systemd-oomd 2>/dev/null || true

echo "Done. Swap now:"
swapon --show
echo "(To persist swap across reboots, add to /etc/fstab: '$SWAP none swap sw 0 0')"
