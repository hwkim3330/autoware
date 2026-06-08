#!/bin/bash
# Download CARLA town maps (lanelet2 + pointcloud) for Autoware and arrange them
# into ~/autoware_map/<Town>/{lanelet2_map.osm,pointcloud_map.pcd}.
# Source: bitbucket carla-simulator/autoware-contents (git-LFS, ~2.3GB all towns).
set -e
DEST="${1:-$HOME/autoware_map}"
SRC="$HOME/autoware-contents"

command -v git-lfs >/dev/null || sudo apt-get install -y git-lfs
git lfs install

if [ ! -d "$SRC" ]; then
  git clone --depth 1 https://bitbucket.org/carla-simulator/autoware-contents.git "$SRC"
fi

cd "$SRC/maps"
for pcd in point_cloud_maps/Town*.pcd; do
  t=$(basename "$pcd" .pcd)
  osm="vector_maps/lanelet2/$t.osm"
  [ -f "$osm" ] || continue
  mkdir -p "$DEST/$t"
  cp "$pcd" "$DEST/$t/pointcloud_map.pcd"
  cp "$osm" "$DEST/$t/lanelet2_map.osm"
  echo "placed $t -> $DEST/$t"
done
echo "Done. Towns available:"; ls "$DEST"
