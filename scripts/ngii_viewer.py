#!/usr/bin/env python3
"""Visualize the raw NGII precise map vs our converted lanelet2 -> PNG.

Renders, side by side:
  LEFT  = raw NGII A2_LINK centerlines (+ B2_SURFACELINEMARK lane edges) -- the
          true precise road geometry as surveyed.
  RIGHT = our converted lanelet2 (left+right boundaries per lanelet) -- what
          Autoware actually loads/drives.
Lets us see if the conversion is faithful or "끊기고 이상함" (fragmented/offset).

Usage: python3 ngii_viewer.py <ngii_shp_dir> <site>   # e.g. .../kcity_ngii kcity
       writes ~/autoware_map/<site>_view.png
"""
import math, os, sys
import xml.etree.ElementTree as ET
import shapefile
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_links(d):
    r = shapefile.Reader(os.path.join(d, "A2_LINK"), encoding="cp949")
    return [s.points for s in r.shapes()]


def read_marks(d):
    try:
        r = shapefile.Reader(os.path.join(d, "B2_SURFACELINEMARK"), encoding="cp949")
        return [s.points for s in r.shapes()]
    except Exception:
        return []


def read_lanelet2(path):
    """Return list of (left_xy, right_xy) from our converted lanelet2 osm."""
    t = ET.parse(path); r = t.getroot()
    nodes = {}
    for n in r.findall("node"):
        lx = ly = None
        for tg in n.findall("tag"):
            if tg.get("k") == "local_x": lx = float(tg.get("v"))
            elif tg.get("k") == "local_y": ly = float(tg.get("v"))
        if lx is not None:
            nodes[n.get("id")] = (lx, ly)
    ways = {}
    for w in r.findall("way"):
        pts = [nodes[nd.get("ref")] for nd in w.findall("nd") if nd.get("ref") in nodes]
        if pts: ways[w.get("id")] = pts
    lls = []
    for rel in r.findall("relation"):
        if not any(tg.get("k") == "type" and tg.get("v") == "lanelet" for tg in rel.findall("tag")):
            continue
        l = rgt = None
        for m in rel.findall("member"):
            if m.get("role") == "left": l = ways.get(m.get("ref"))
            elif m.get("role") == "right": rgt = ways.get(m.get("ref"))
        if l and rgt: lls.append((l, rgt))
    return lls


def main():
    shp_dir, site = sys.argv[1], sys.argv[2]
    links = read_links(shp_dir)
    marks = read_marks(shp_dir)
    # local origin = centroid of link verts (match converter)
    allp = [p for ln in links for p in ln]
    ox = sum(p[0] for p in allp) / len(allp); oy = sum(p[1] for p in allp) / len(allp)
    ll_path = os.path.expanduser(f"~/autoware_map/{site}/lanelet2_map.osm")
    lls = read_lanelet2(ll_path) if os.path.exists(ll_path) else []

    fig, ax = plt.subplots(1, 2, figsize=(22, 11))
    # LEFT: raw NGII
    for ln in links:
        xs = [p[0] - ox for p in ln]; ys = [p[1] - oy for p in ln]
        ax[0].plot(xs, ys, "-", color="#1565c0", lw=0.6)
    for mk in marks:
        xs = [p[0] - ox for p in mk]; ys = [p[1] - oy for p in mk]
        ax[0].plot(xs, ys, "-", color="#bbbbbb", lw=0.3)
    ax[0].set_title(f"RAW NGII: A2_LINK {len(links)} links (blue) + B2 marks {len(marks)} (grey)")
    # RIGHT: converted lanelet2
    for l, rgt in lls:
        ax[1].plot([p[0] for p in l], [p[1] for p in l], "-", color="#2e7d32", lw=0.5)
        ax[1].plot([p[0] for p in rgt], [p[1] for p in rgt], "-", color="#c62828", lw=0.5)
    ax[1].set_title(f"CONVERTED lanelet2: {len(lls)} lanelets (L=green R=red)")
    for a in ax:
        a.set_aspect("equal"); a.grid(True, alpha=0.2)
    out = os.path.expanduser(f"~/autoware_map/{site}_view.png")
    fig.tight_layout(); fig.savefig(out, dpi=90)
    print(f"wrote {out}  (links={len(links)} marks={len(marks)} lanelets={len(lls)})")


if __name__ == "__main__":
    main()
