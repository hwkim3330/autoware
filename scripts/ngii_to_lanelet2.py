#!/usr/bin/env python3
"""NGII 정밀도로지도 (B110, 국토정보플랫폼) -> Autoware lanelet2 map (WITH elevation).

The NGII precise map ships real lane topology AND real elevation:
  A2_LINK (PolyLineZ)            - per-lane centerlines (x,y,Z) + FromNodeID/ToNodeID
                                   (routing graph) + R_LinkID/L_LinkID (lane adjacency)
  B2_SURFACELINEMARK (PolyLineZ) - painted lane-boundary linestrings (x,y,Z), tagged
                                   with the links on their right (R_LinkID)/left (L_LinkID)
We build one lanelet per A2_LINK: centerline from the link, left/right boundaries
matched from B2 marks (mark.R_LinkID==X -> X's LEFT edge; L_LinkID==X -> RIGHT),
offset fallback when a painted edge is missing. **Z (elevation) is preserved** so
Pangyo's ~53 m of terrain is in the map (ele tag per node), not flattened.
Boundary points snap to shared lanelet2 nodes by (x,y) so consecutive links
(A.ToNode==B.FromNode) share endpoints -> routable. CRS UTM-K(EPSG:5179)->local m.

Usage: python3 ngii_to_lanelet2.py <ngii_shp_dir> <site_name>
"""
import math, os, sys
import xml.etree.ElementTree as ET
import shapefile  # pyshp
from pyproj import Transformer

LANE_HALF = 1.65
SPEED_BY_RANK = {"1": 80, "2": 70, "3": 60, "4": 50, "5": 50, "6": 40, "7": 30, "8": 30, "9": 30}


def read_layer(d, name):
    """Return [(points_xyz, rec)] with per-vertex elevation (PolyLineZ)."""
    r = shapefile.Reader(os.path.join(d, name), encoding="cp949")
    fields = [f[0] for f in r.fields[1:]]
    out = []
    for sr in r.shapeRecords():
        sh = sr.shape
        zs = getattr(sh, "z", None) or [0.0] * len(sh.points)
        pts = [(p[0], p[1], zs[i] if i < len(zs) else 0.0) for i, p in enumerate(sh.points)]
        out.append((pts, dict(zip(fields, sr.record))))
    return out


def offset(line, half, side):
    out = []
    n = len(line)
    for i, (x, y, z) in enumerate(line):
        if i == 0:
            dx, dy = line[1][0] - x, line[1][1] - y
        elif i == n - 1:
            dx, dy = x - line[i - 1][0], y - line[i - 1][1]
        else:
            dx, dy = line[i + 1][0] - line[i - 1][0], line[i + 1][1] - line[i - 1][1]
        L = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / L, dx / L
        out.append((x + side * nx * half, y + side * ny * half, z))
    return out


def orient(bound, center):
    if not bound or len(center) < 2:
        return bound
    cs = center[0]
    d_same = math.hypot(bound[0][0] - cs[0], bound[0][1] - cs[1])
    d_flip = math.hypot(bound[-1][0] - cs[0], bound[-1][1] - cs[1])
    return bound if d_same <= d_flip else bound[::-1]


def main():
    if len(sys.argv) < 3:
        print("usage: ngii_to_lanelet2.py <ngii_shp_dir> <site_name>"); sys.exit(1)
    shp_dir, site = sys.argv[1], sys.argv[2]
    links = read_layer(shp_dir, "A2_LINK")
    marks = read_layer(shp_dir, "B2_SURFACELINEMARK")
    print(f"  A2_LINK: {len(links)} links, B2_SURFACELINEMARK: {len(marks)} marks")

    allpts = [p for pts, _ in links for p in pts]
    ox = sum(p[0] for p in allpts) / len(allpts)
    oy = sum(p[1] for p in allpts) / len(allpts)
    zs = [p[2] for p in allpts]
    print(f"  elevation: {min(zs):.1f}..{max(zs):.1f} m (span {max(zs)-min(zs):.1f} m) -- preserved")
    to_wgs = Transformer.from_crs("EPSG:5179", "EPSG:4326", always_xy=True)
    lon0, lat0 = to_wgs.transform(ox, oy)

    def loc(pts):
        return [(x - ox, y - oy, z) for x, y, z in pts]

    left_marks, right_marks = {}, {}
    for pts, rec in marks:
        if rec.get("R_LinkID"):
            left_marks.setdefault(rec["R_LinkID"], []).append(loc(pts))
        if rec.get("L_LinkID"):
            right_marks.setdefault(rec["L_LinkID"], []).append(loc(pts))

    out = ET.Element("osm", {"version": "0.6", "generator": "ngii_to_lanelet2"})
    ET.SubElement(out, "MetaInfo", {"format_version": "1", "map_version": "1"})
    nid = [0]; node_cache = {}

    def node(x, y, z):
        key = (round(x, 2), round(y, 2))
        if key in node_cache:
            return node_cache[key]
        nid[0] += 1
        n = ET.SubElement(out, "node", {"id": str(nid[0]), "lat": "0", "lon": "0"})
        ET.SubElement(n, "tag", {"k": "local_x", "v": f"{x:.3f}"})
        ET.SubElement(n, "tag", {"k": "local_y", "v": f"{y:.3f}"})
        ET.SubElement(n, "tag", {"k": "ele", "v": f"{z:.2f}"})   # real NGII elevation
        node_cache[key] = nid[0]
        return nid[0]

    def linestring(pts, subtype):
        nid[0] += 1
        w = ET.SubElement(out, "way", {"id": str(nid[0])})
        for (x, y, z) in pts:
            ET.SubElement(w, "nd", {"ref": str(node(x, y, z))})
        ET.SubElement(w, "tag", {"k": "type", "v": "line_thin"})
        ET.SubElement(w, "tag", {"k": "subtype", "v": subtype})
        return nid[0]

    def newid():
        nid[0] += 1
        return nid[0]

    n_ll = 0
    for pts, rec in links:
        lid = rec["ID"]
        center = loc(pts)
        if len(center) < 2:
            continue
        lm = left_marks.get(lid); rm = right_marks.get(lid)
        left = orient(max(lm, key=len), center) if lm else offset(center, LANE_HALF, +1)
        right = orient(max(rm, key=len), center) if rm else offset(center, LANE_HALF, -1)
        lw = linestring(left, "solid"); rw = linestring(right, "solid")
        rel = ET.SubElement(out, "relation", {"id": str(newid())})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(lw), "role": "left"})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(rw), "role": "right"})
        ET.SubElement(rel, "tag", {"k": "type", "v": "lanelet"})
        ET.SubElement(rel, "tag", {"k": "subtype", "v": "road"})
        ET.SubElement(rel, "tag", {"k": "location", "v": "urban"})
        ET.SubElement(rel, "tag", {"k": "one_way", "v": "yes"})
        ET.SubElement(rel, "tag", {"k": "speed_limit", "v": f"{SPEED_BY_RANK.get(str(rec.get('RoadRank','')),30)}.00"})
        n_ll += 1

    out_dir = os.path.expanduser(f"~/autoware_map/{site}")
    os.makedirs(out_dir, exist_ok=True)
    ET.ElementTree(out).write(os.path.join(out_dir, "lanelet2_map.osm"),
                              encoding="utf-8", xml_declaration=True)
    open(os.path.join(out_dir, "map_projector_info.yaml"), "w").write("projector_type: local\n")
    open(os.path.join(out_dir, f"{site}.origin"), "w").write(f"{lat0:.7f} {lon0:.7f}\n")
    # PCD placeholder carrying the real elevation (so it's not a flat plane either)
    with open(os.path.join(out_dir, "pointcloud_map.pcd"), "w") as f:
        sample = allpts[:6000]
        f.write("# .PCD v0.7\nVERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n")
        f.write(f"WIDTH {len(sample)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {len(sample)}\nDATA ascii\n")
        for x, y, z in sample:
            f.write(f"{x-ox:.2f} {y-oy:.2f} {z:.2f}\n")
    print(f"==> {site}: {n_ll} lanelets (3D, elevation-preserved) -> {out_dir}/")
    print(f"    origin (WGS84): {lat0:.6f}, {lon0:.6f}")


if __name__ == "__main__":
    main()
