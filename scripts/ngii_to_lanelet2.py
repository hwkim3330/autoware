#!/usr/bin/env python3
"""NGII 정밀도로지도 (B110) -> Autoware lanelet2 (CONNECTED routing + elevation).

The NGII precise map ships real lane topology + elevation:
  A2_LINK (PolyLineZ)  - per-lane centerlines (x,y,Z) + FromNodeID/ToNodeID graph
We build one lanelet per A2_LINK, boundaries by offsetting the centerline (clean,
consistent geometry), then WIRE CONNECTIVITY using the FromNode/ToNode graph:
each lanelet's boundary START points are snapped to its predecessor lanelet's
boundary END points (predecessor = the incoming link at this link's FromNode whose
heading best continues into it). lanelet2 treats B as "following" A when they share
boundary endpoints -> a connected routing graph (the old version offset each lane
independently -> reachable~5; this chains them). Elevation (Z) preserved. Nodes get
both WGS84 lat/lon and local_x/local_y; emitted nodes-first (lanelet2 parse order).
UTM-K (EPSG:5179) -> local m about centroid.

Usage: python3 ngii_to_lanelet2.py <ngii_shp_dir> <site_name>
"""
import math, os, sys
import xml.etree.ElementTree as ET
import shapefile  # pyshp
from pyproj import Transformer

LANE_HALF = 1.65
SPEED_BY_RANK = {"1": 80, "2": 70, "3": 60, "4": 50, "5": 50, "6": 40, "7": 30, "8": 30, "9": 30}


def read_layer(d, name):
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


def heading(line, at_start):
    if len(line) < 2:
        return 0.0
    a, b = (line[0], line[1]) if at_start else (line[-2], line[-1])
    return math.atan2(b[1] - a[1], b[0] - a[0])


def main():
    if len(sys.argv) < 3:
        print("usage: ngii_to_lanelet2.py <ngii_shp_dir> <site_name>"); sys.exit(1)
    shp_dir, site = sys.argv[1], sys.argv[2]
    links = read_layer(shp_dir, "A2_LINK")
    print(f"  A2_LINK: {len(links)} links")
    allpts = [p for pts, _ in links for p in pts]
    ox = sum(p[0] for p in allpts) / len(allpts)
    oy = sum(p[1] for p in allpts) / len(allpts)
    zs = [p[2] for p in allpts]
    print(f"  elevation: {min(zs):.1f}..{max(zs):.1f} m (span {max(zs)-min(zs):.1f} m)")
    to_wgs = Transformer.from_crs("EPSG:5179", "EPSG:4326", always_xy=True)
    lon0, lat0 = to_wgs.transform(ox, oy)

    def loc(pts):
        return [(x - ox, y - oy, z) for x, y, z in pts]

    # PASS 1: build per-link centerline + offset boundaries
    L = {}
    for pts, rec in links:
        c = loc(pts)
        if len(c) < 2:
            continue
        L[rec["ID"]] = {"c": c, "left": offset(c, LANE_HALF, +1),
                        "right": offset(c, LANE_HALF, -1), "rec": rec}
    # incoming links per node (links whose ToNode == that node)
    # PASS 2: NODE-WELDING connectivity. The NGII A2_LINK FromNodeID/ToNodeID IS the
    # explicit routing graph. At each node, weld EVERY link endpoint that meets there
    # to a single shared (left,right) anchor: an incoming link contributes its END
    # boundary points, an outgoing link its START boundary points. After welding, every
    # incoming link's END == every outgoing link's START (shared vertices) -> lanelet2
    # routes incoming->outgoing for ALL pairs at the node (forks/merges/junctions),
    # not just one straightest pair. Anchors are computed once from ORIGINAL geometry
    # (no cascade), so chains stay intact. The 'end' anchor and 'start' anchor of a
    # node are computed separately then unified so an A.ToNode==B.FromNode pair shares.
    touch = {}   # node_id -> list of (lid, "start"|"end")
    for lid, d in L.items():
        fn = d["rec"].get("FromNodeID", ""); tn = d["rec"].get("ToNodeID", "")
        if fn:
            touch.setdefault(fn, []).append((lid, "start"))
        if tn:
            touch.setdefault(tn, []).append((lid, "end"))

    def lp(lid, side, end):   # endpoint (x,y,z) of a link's left/right boundary
        arr = L[lid][side]
        return arr[-1] if end == "end" else arr[0]

    n_nodes = 0
    for node_id, members in touch.items():
        if len(members) < 2:
            continue
        # left/right anchors = mean of all endpoints meeting at this node
        lxs = [lp(lid, "left", e) for lid, e in members]
        rxs = [lp(lid, "right", e) for lid, e in members]
        la_ = (sum(p[0] for p in lxs) / len(lxs), sum(p[1] for p in lxs) / len(lxs),
               sum(p[2] for p in lxs) / len(lxs))
        ra_ = (sum(p[0] for p in rxs) / len(rxs), sum(p[1] for p in rxs) / len(rxs),
               sum(p[2] for p in rxs) / len(rxs))
        for lid, e in members:
            if e == "end":
                L[lid]["left"][-1] = la_; L[lid]["right"][-1] = ra_
            else:
                L[lid]["left"][0] = la_; L[lid]["right"][0] = ra_
        n_nodes += 1
    print(f"  connectivity: welded {n_nodes} shared nodes across {len(L)} links")

    # PASS 3: emit (nodes first, then ways + relations)
    out = ET.Element("osm", {"version": "0.6", "generator": "ngii_to_lanelet2"})
    ET.SubElement(out, "MetaInfo", {"format_version": "1", "map_version": "1"})
    nid = [0]; node_cache = {}; node_elems = []; body_elems = []

    def node(x, y, z):
        key = (round(x, 2), round(y, 2))
        if key in node_cache:
            return node_cache[key]
        nid[0] += 1
        lon_n, lat_n = to_wgs.transform(x + ox, y + oy)
        n = ET.Element("node", {"id": str(nid[0]), "lat": f"{lat_n:.9f}", "lon": f"{lon_n:.9f}"})
        ET.SubElement(n, "tag", {"k": "local_x", "v": f"{x:.3f}"})
        ET.SubElement(n, "tag", {"k": "local_y", "v": f"{y:.3f}"})
        ET.SubElement(n, "tag", {"k": "ele", "v": f"{z:.2f}"})
        node_elems.append(n); node_cache[key] = nid[0]
        return nid[0]

    def distinct(pts):
        seen = []
        for p in pts:
            k = (round(p[0], 2), round(p[1], 2))
            if not seen or seen[-1] != k:
                seen.append(k)
        return len(seen)

    def linestring(pts):
        refs, prev = [], None
        for (x, y, z) in pts:
            r = node(x, y, z)
            if r != prev:               # drop consecutive-duplicate refs
                refs.append(r); prev = r
        if len(refs) < 2:
            return None
        nid[0] += 1
        w = ET.Element("way", {"id": str(nid[0])})
        for r in refs:
            ET.SubElement(w, "nd", {"ref": str(r)})
        ET.SubElement(w, "tag", {"k": "type", "v": "line_thin"})
        ET.SubElement(w, "tag", {"k": "subtype", "v": "solid"})
        body_elems.append(w)
        return nid[0]

    n_ll = 0
    for lid, d in L.items():
        if distinct(d["left"]) < 2 or distinct(d["right"]) < 2:
            continue
        lw = linestring(d["left"]); rw = linestring(d["right"])
        if lw is None or rw is None:
            continue
        nid[0] += 1
        rel = ET.Element("relation", {"id": str(nid[0])}); body_elems.append(rel)
        ET.SubElement(rel, "member", {"type": "way", "ref": str(lw), "role": "left"})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(rw), "role": "right"})
        ET.SubElement(rel, "tag", {"k": "type", "v": "lanelet"})
        ET.SubElement(rel, "tag", {"k": "subtype", "v": "road"})
        ET.SubElement(rel, "tag", {"k": "location", "v": "urban"})
        ET.SubElement(rel, "tag", {"k": "one_way", "v": "yes"})
        ET.SubElement(rel, "tag", {"k": "speed_limit", "v": f"{SPEED_BY_RANK.get(str(d['rec'].get('RoadRank','')),30)}.00"})
        n_ll += 1

    for n in node_elems:
        out.append(n)
    for b in body_elems:
        out.append(b)
    out_dir = os.path.expanduser(f"~/autoware_map/{site}")
    os.makedirs(out_dir, exist_ok=True)
    ET.ElementTree(out).write(os.path.join(out_dir, "lanelet2_map.osm"),
                              encoding="utf-8", xml_declaration=True)
    open(os.path.join(out_dir, "map_projector_info.yaml"), "w").write("projector_type: local\n")
    open(os.path.join(out_dir, f"{site}.origin"), "w").write(f"{lat0:.7f} {lon0:.7f}\n")
    # dense road-network point cloud: every centerline + both lane edges, finely
    # resampled (~0.5 m), so rviz shows the full 3D road surface (elevation incl.).
    cloud = []
    for d in L.values():
        for line in (d["left"], d["right"]):     # lane EDGES only (cleaner; the
            for i in range(len(line) - 1):        # lanelet vector map shows centers)
                x0, y0, z0 = line[i]; x1, y1, z1 = line[i + 1]
                seg = math.hypot(x1 - x0, y1 - y0)
                steps = max(1, int(seg / 1.5))    # 1.5 m spacing (was 0.5 -> 3x cleaner)
                for s in range(steps):
                    t = s / steps
                    # cloud sits 0.3 m BELOW the lane surface = the ground the wheels
                    # rest on, so the vehicle model sits ON the cloud (not buried in it)
                    cloud.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t,
                                  z0 + (z1 - z0) * t - 0.3))
    with open(os.path.join(out_dir, "pointcloud_map.pcd"), "w") as f:
        f.write("# .PCD v0.7\nVERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n")
        f.write(f"WIDTH {len(cloud)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {len(cloud)}\nDATA ascii\n")
        for x, y, z in cloud:
            f.write(f"{x:.2f} {y:.2f} {z:.2f}\n")
    print(f"==> {site}: {n_ll} lanelets (connected + 3D), {len(cloud)} cloud pts -> {out_dir}/  origin {lat0:.6f},{lon0:.6f}")


if __name__ == "__main__":
    main()
