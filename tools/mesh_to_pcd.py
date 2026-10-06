#!/usr/bin/env python3
"""Sample an AWSIM scene mesh (OBJ) into a dense point cloud map for NDT.

Why: Pangyo's original pointcloud_map.pcd was generated from footprints with a
coarse vertical sweep and was ~7x sparser than Shinjuku per NDT voxel (4.87 vs
36.42 points in 2 m voxels), so NDT's score sat at the gate everywhere and
Autoware stopped after ~236 m (container_patches/ndt_pangyo_notes.md). The
scene mesh AWSIM renders *is* the geometry the simulated LiDAR sees, so a map
sampled from it matches the sensor by construction.

Sampling is area-weighted and per material: walls (material "building") at a
fine spacing, terrain ("ground") coarser -- flat ground adds file size but
little horizontal constraint for NDT. Points are then thinned to one per voxel
of the same spacing. The OBJ->map transform must be measured, not guessed; for
pangyo_regen it is  map = (obj_z, -obj_x, obj_y) + (32278.5, 41244.6, 0)
(verified on 1,650 building vertices, median 0.30 m to the old PCD).

    python3 mesh_to_pcd.py environment.obj out.pcd \\
        --offset 32278.5 41244.6 0 --wall 0.2 --ground 0.5
"""
import argparse
import sys

import numpy as np
import trimesh


def sample_surface(mesh, spacing, rng):
    """Area-weighted uniform samples at roughly one point per spacing^2."""
    n = int(mesh.area / (spacing * spacing))
    if n <= 0:
        return np.zeros((0, 3))
    pts, _ = trimesh.sample.sample_surface(mesh, n, seed=int(rng.integers(1 << 31)))
    return np.asarray(pts)


def voxel_thin(pts, size):
    """Keep one point per voxel (the first seen)."""
    if len(pts) == 0:
        return pts
    keys = np.floor(pts / size).astype(np.int64)
    _, idx = np.unique(keys, axis=0, return_index=True)
    return pts[np.sort(idx)]


def write_pcd_binary(path, pts):
    pts = np.ascontiguousarray(pts, dtype=np.float32)
    header = (
        "# .PCD v0.7 - Point Cloud Data file format\n"
        "VERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n"
        f"WIDTH {len(pts)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {len(pts)}\nDATA binary\n"
    )
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(pts.tobytes())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("obj")
    ap.add_argument("out")
    ap.add_argument("--offset", type=float, nargs=3, default=(0.0, 0.0, 0.0),
                    help="added after the axis swap: map = (obj_z, -obj_x, obj_y) + offset")
    ap.add_argument("--wall", type=float, default=0.2, help="spacing for non-ground materials [m]")
    ap.add_argument("--ground", type=float, default=0.5, help="spacing for the 'ground' material [m]")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    scene = trimesh.load(a.obj, process=False)
    geoms = scene.geometry if hasattr(scene, "geometry") else {"mesh": scene}
    parts = []
    for name, g in geoms.items():
        spacing = a.ground if "ground" in name.lower() else a.wall
        pts = voxel_thin(sample_surface(g, spacing, rng), spacing)
        print(f"  {name:12s} area {g.area:12.0f} m2  spacing {spacing:.2f} m  -> {len(pts):,} pts", file=sys.stderr)
        parts.append(pts)
    obj = np.concatenate(parts)
    # OBJ is Unity-style y-up; map frame is z-up ENU (measured mapping, see docstring)
    mp = np.stack([obj[:, 2], -obj[:, 0], obj[:, 1]], axis=1) + np.asarray(a.offset)
    write_pcd_binary(a.out, mp)
    print(f"wrote {a.out}: {len(mp):,} points, x {mp[:,0].min():.1f}..{mp[:,0].max():.1f} "
          f"y {mp[:,1].min():.1f}..{mp[:,1].max():.1f} z {mp[:,2].min():.1f}..{mp[:,2].max():.1f}", file=sys.stderr)


if __name__ == "__main__":
    main()
