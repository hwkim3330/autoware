#!/usr/bin/env python3
"""NGII 정밀도로지도 (B110, 국토정보플랫폼) -> Autoware lanelet2 map.

Unlike osm_to_lanelet2.py (which guesses lane geometry from OSM centerlines and
can't build a routable graph), the NGII precise map ships the real lane topology:
  A2_LINK            - per-lane centerlines + FromNodeID/ToNodeID (routing graph)
                       + R_LinkID/L_LinkID (lane-change adjacency)
  B2_SURFACELINEMARK - the painted lane-boundary linestrings, tagged with the
                       links on their right (R_LinkID) / left (L_LinkID)
  A1_NODE            - junction/endpoint nodes

We build one lanelet per A2_LINK: centerline from the link, left/right boundaries
matched from B2 marks (a mark with R_LinkID==X is X's LEFT edge; L_LinkID==X is
X's RIGHT edge), falling back to a centerline offset when a painted edge is
missing. Boundary points are snapped to shared lanelet2 nodes by coordinate, so
consecutive links (A.ToNode==B.FromNode) share endpoints -> Autoware's routing
graph connects them. Coordinates: NGII UTM-K (EPSG:5179) -> local meters about the
map centroid (Autoware projector_type: local). The centroid's WGS84 lat/lon is
written to <site>.origin for the OSM-basemap app + gateway.

Usage:
    python3 ngii_to_lanelet2.py ~/autoware_map/ngii/pangyo_ngii pangyo
"""
import math
import os
import sys
import xml.etree.ElementTree as ET

import shapefile  # pyshp
from pyproj import Transformer

LANE_HALF = 1.65   # fallback half-width (m) when a painted edge is missing
SPEED_BY_RANK = {"1": 80, "2": 70, "3": 60, "4": 50, "5": 50, "6": 40, "7": 30, "8": 30, "9": 30}


def read_layer(d, name):
    r = shapefile.Reader(os.path.join(d, name), encoding="cp949")
    fields = [f[0] for f in r.fields[1:]]
    out = []
    for sr in r.shapeRecords():
        rec = dict(zip(fields, sr.record))
        out.append((sr.shape.points, rec))
    return out


def offset(line, half, side):
    """Offset a polyline left(+1)/right(-1) by half metres (per-vertex normal)."""
    out = []
    n = len(line)
    for i, (x, y) in enumerate(line):
        if i == 0:
            dx, dy = line[1][0] - x, line[1][1] - y
        elif i == n - 1:
            dx, dy = x - line[i - 1][0], y - line[i - 1][1]
        else:
            dx, dy = line[i + 1][0] - line[i - 1][0], line[i + 1][1] - line[i - 1][1]
        L = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / L, dx / L          # left normal
        out.append((x + side * nx * half, y + side * ny * half))
    return out


def orient(bound, center):
    """Flip a boundary so it runs the same direction as the centerline."""
    if not bound or len(center) < 2:
        return bound
    cs, ce = center[0], center[-1]
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

    # local origin = centroid of all link vertices (UTM-K meters)
    allpts = [p for pts, _ in links for p in pts]
    ox = sum(p[0] for p in allpts) / len(allpts)
    oy = sum(p[1] for p in allpts) / len(allpts)
    to_wgs = Transformer.from_crs("EPSG:5179", "EPSG:4326", always_xy=True)
    lon0, lat0 = to_wgs.transform(ox, oy)
    print(f"  origin UTM-K=({ox:.1f},{oy:.1f}) -> WGS84=({lat0:.6f},{lon0:.6f})")

    def loc(pts):
        return [(x - ox, y - oy) for x, y in pts]

    # index marks by the link they bound: R_LinkID -> mark is that link's LEFT edge;
    # L_LinkID -> that link's RIGHT edge.
    left_marks, right_marks = {}, {}
    for pts, rec in marks:
        if rec.get("R_LinkID"):
            left_marks.setdefault(rec["R_LinkID"], []).append(loc(pts))
        if rec.get("L_LinkID"):
            right_marks.setdefault(rec["L_LinkID"], []).append(loc(pts))

    out = ET.Element("osm", {"version": "0.6", "generator": "ngii_to_lanelet2"})
    ET.SubElement(out, "MetaInfo", {"format_version": "1", "map_version": "1"})
    nid = [0]; node_cache = {}

    def node(x, y, z=0.0):
        key = (round(x, 2), round(y, 2))          # snap @1cm -> shared connectivity
        if key in node_cache:
            return node_cache[key]
        nid[0] += 1
        n = ET.SubElement(out, "node", {"id": str(nid[0]), "lat": "0", "lon": "0"})
        ET.SubElement(n, "tag", {"k": "local_x", "v": f"{x:.3f}"})
        ET.SubElement(n, "tag", {"k": "local_y", "v": f"{y:.3f}"})
        ET.SubElement(n, "tag", {"k": "ele", "v": f"{z:.2f}"})
        node_cache[key] = nid[0]
        return nid[0]

    def linestring(pts, subtype):
        nid[0] += 1
        w = ET.SubElement(out, "way", {"id": str(nid[0])})
        for (x, y) in pts:
            ET.SubElement(w, "nd", {"ref": str(node(x, y))})
        ET.SubElement(w, "tag", {"k": "type", "v": "line_thin"})
        ET.SubElement(w, "tag", {"k": "subtype", "v": subtype})
        return nid[0]

    n_ll = 0
    for pts, rec in links:
        lid = rec["ID"]
        center = loc(pts)
        if len(center) < 2:
            continue
        lm = left_marks.get(lid)
        rm = right_marks.get(lid)
        left = orient(max(lm, key=len), center) if lm else offset(center, LANE_HALF, +1)
        right = orient(max(rm, key=len), center) if rm else offset(center, LANE_HALF, -1)
        lw = linestring(left, "solid")
        rw = linestring(right, "solid")
        rel = ET.SubElement(out, "relation", {"id": str(_inc(nid))})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(lw), "role": "left"})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(rw), "role": "right"})
        ET.SubElement(rel, "tag", {"k": "type", "v": "lanelet"})
        ET.SubElement(rel, "tag", {"k": "subtype", "v": "road"})
        ET.SubElement(rel, "tag", {"k": "location", "v": "urban"})
        ET.SubElement(rel, "tag", {"k": "one_way", "v": "yes"})
        spd = SPEED_BY_RANK.get(str(rec.get("RoadRank", "")), 30)
        ET.SubElement(rel, "tag", {"k": "speed_limit", "v": f"{spd}.00"})
        n_ll += 1

    out_dir = os.path.expanduser(f"~/autoware_map/{site}")
    os.makedirs(out_dir, exist_ok=True)
    ET.ElementTree(out).write(os.path.join(out_dir, "lanelet2_map.osm"),
                              encoding="utf-8", xml_declaration=True)
    with open(os.path.join(out_dir, "map_projector_info.yaml"), "w") as f:
        f.write("projector_type: local\n")
    with open(os.path.join(out_dir, f"{site}.origin"), "w") as f:
        f.write(f"{lat0:.7f} {lon0:.7f}\n")
    _dummy_pcd(os.path.join(out_dir, "pointcloud_map.pcd"),
               [(p[0] - ox, p[1] - oy) for p in allpts[:6000]])
    print(f"==> {site}: {n_ll} lanelets, {nid[0]} elements -> {out_dir}/")
    print(f"    origin (WGS84): {lat0:.6f}, {lon0:.6f}")


def _inc(nid):
    nid[0] += 1
    return nid[0]


def _dummy_pcd(path, pts):
    if not pts:
        pts = [(0.0, 0.0)]
    with open(path, "w") as f:
        f.write("# .PCD v0.7 - placeholder (GNSS localization)\n")
        f.write("VERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n")
        f.write(f"WIDTH {len(pts)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {len(pts)}\nDATA ascii\n")
        for x, y in pts:
            f.write(f"{x:.2f} {y:.2f} 0.00\n")


if __name__ == "__main__":
    main()
