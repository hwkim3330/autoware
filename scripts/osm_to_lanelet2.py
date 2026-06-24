#!/usr/bin/env python3
"""OSM (real roads) -> Autoware lanelet2 map.

Builds a lanelet2 map (.osm with lanelet tags) from the same OpenStreetMap data
used for the CARLA OpenDRIVE world, projected to local meters around the site
origin (matching Autoware `projector_type: local` and scripts/osm_to_carla.py's
tmerc). For each drivable OSM highway way it emits a lanelet: a centerline plus
left/right boundary linestrings offset by half the lane width. Junction nodes
shared between ways are emitted as shared lanelet2 nodes so consecutive lanelets
connect for routing.

Pairs with osm_to_carla.py: same site, same projection -> the lanelet2 map and the
CARLA world align. Localization is GNSS-based (the CARLA interface publishes a
ground-truth GNSS pose), so no pointcloud map is required; a tiny placeholder PCD
is written just so the Autoware map_loader is happy.

Usage:
    python3 osm_to_lanelet2.py soongsil      # -> ~/autoware_map/soongsil/
    python3 osm_to_lanelet2.py pangyo
"""
import math
import os
import sys
import xml.etree.ElementTree as ET

OSM_DIR = os.path.expanduser("~/autoware_map/osm")
OUT_BASE = os.path.expanduser("~/autoware_map")

SITES = {
    "soongsil": (37.4963, 126.9573),
    "pangyo":   (37.3947, 127.1112),
    "kcity":    (37.2410, 126.7720),
}

# OSM highway classes we treat as drivable, with a default lane width (m, one side
# of center -> full corridor = 2x). motorway/primary wider than residential.
DRIVABLE = {
    "motorway": 1.85, "motorway_link": 1.85, "trunk": 1.85, "trunk_link": 1.85,
    "primary": 1.75, "primary_link": 1.75, "secondary": 1.75, "secondary_link": 1.75,
    "tertiary": 1.6, "tertiary_link": 1.6, "residential": 1.5, "unclassified": 1.5,
    "service": 1.4, "living_street": 1.5,
}
SPEED_KMH = {"motorway": 80, "trunk": 70, "primary": 60, "secondary": 50,
             "tertiary": 50, "residential": 30, "service": 20, "living_street": 20}


def project(lat, lon, lat0, lon0):
    """Transverse-mercator-ish local meters around (lat0,lon0). Matches the xodr's
    +proj=tmerc closely enough for alignment (small-area equirectangular)."""
    R = 6378137.0
    x = math.radians(lon - lon0) * R * math.cos(math.radians(lat0))
    y = math.radians(lat - lat0) * R
    return x, y


class IdGen:
    def __init__(self): self.n = 0
    def __call__(self):
        self.n += 1
        return self.n


def main():
    site = sys.argv[1] if len(sys.argv) > 1 else None
    if site not in SITES:
        print("usage: osm_to_lanelet2.py", list(SITES)); sys.exit(1)
    lat0, lon0 = SITES[site]
    osm_path = os.path.join(OSM_DIR, f"{site}.osm")
    if not os.path.exists(osm_path):
        print(f"missing {osm_path} -- run osm_to_carla.py {site} first"); sys.exit(1)

    tree = ET.parse(osm_path)
    root = tree.getroot()
    # raw OSM nodes -> local xy
    nodes = {}
    for nd in root.findall("node"):
        nid = nd.get("id")
        nodes[nid] = project(float(nd.get("lat")), float(nd.get("lon")), lat0, lon0)
    # count node usage to find junctions (shared nodes)
    usage = {}
    ways = []
    for w in root.findall("way"):
        tags = {t.get("k"): t.get("v") for t in w.findall("tag")}
        hw = tags.get("highway")
        if hw not in DRIVABLE:
            continue
        refs = [n.get("ref") for n in w.findall("nd") if n.get("ref") in nodes]
        if len(refs) < 2:
            continue
        ways.append((refs, hw, tags))
        for r in refs:
            usage[r] = usage.get(r, 0) + 1

    gid = IdGen()
    out = ET.Element("osm", {"version": "0.6", "generator": "osm_to_lanelet2"})
    # lanelet2 wants a MGRS/local origin marker node sometimes; local projector is fine.

    # shared lanelet2 boundary nodes keyed by (osm_node_id, side) so lanelets that
    # meet at a junction node share the SAME boundary points -> routable.
    bnode_cache = {}
    pcd_pts = []

    def bnode(osm_id, side, x, y):
        key = (osm_id, side)
        if key in bnode_cache:
            return bnode_cache[key]
        nid = gid()
        # lanelet2 local frame: lat/lon unused (local), but tools expect them; use
        # local_x/local_y tags (Autoware lanelet2 local projector reads these).
        n = ET.SubElement(out, "node", {"id": str(nid), "lat": "0", "lon": "0"})
        ET.SubElement(n, "tag", {"k": "local_x", "v": f"{x:.3f}"})
        ET.SubElement(n, "tag", {"k": "local_y", "v": f"{y:.3f}"})
        ET.SubElement(n, "tag", {"k": "ele", "v": "0"})
        bnode_cache[key] = nid
        pcd_pts.append((x, y))
        return nid

    def linestring(point_ids, subtype):
        wid = gid()
        w = ET.SubElement(out, "way", {"id": str(wid)})
        for pid in point_ids:
            ET.SubElement(w, "nd", {"ref": str(pid)})
        ET.SubElement(w, "tag", {"k": "type", "v": "line_thin"})
        ET.SubElement(w, "tag", {"k": "subtype", "v": subtype})
        return wid

    n_lanelets = 0
    for refs, hw, tags in ways:
        halfw = DRIVABLE[hw]
        pts = [nodes[r] for r in refs]
        # per-vertex left/right offset using the average of adjacent segment normals
        left_ids, right_ids = [], []
        for i, (x, y) in enumerate(pts):
            # tangent
            if i == 0:
                dx, dy = pts[1][0] - x, pts[1][1] - y
            elif i == len(pts) - 1:
                dx, dy = x - pts[i - 1][0], y - pts[i - 1][1]
            else:
                dx, dy = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
            L = math.hypot(dx, dy) or 1.0
            # left normal = (-dy, dx)/L
            nx, ny = -dy / L, dx / L
            lx, ly = x + nx * halfw, y + ny * halfw
            rx, ry = x - nx * halfw, y - ny * halfw
            # share boundary nodes at junction endpoints so neighbours connect
            shared = (i == 0 or i == len(pts) - 1) and usage.get(refs[i], 0) > 1
            tagk = refs[i] if shared else f"{refs[i]}_{id(refs)}_{i}"
            left_ids.append(bnode(tagk, "L", lx, ly))
            right_ids.append(bnode(tagk, "R", rx, ry))

        lw = linestring(left_ids, "solid")
        rw = linestring(right_ids, "solid")
        rel = ET.SubElement(out, "relation", {"id": str(gid())})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(lw), "role": "left"})
        ET.SubElement(rel, "member", {"type": "way", "ref": str(rw), "role": "right"})
        ET.SubElement(rel, "tag", {"k": "type", "v": "lanelet"})
        ET.SubElement(rel, "tag", {"k": "subtype", "v": "road"})
        ET.SubElement(rel, "tag", {"k": "location", "v": "urban"})
        ET.SubElement(rel, "tag", {"k": "one_way", "v": "no"})
        ET.SubElement(rel, "tag", {"k": "speed_limit",
                                   "v": f"{SPEED_KMH.get(hw, 30)}.00"})
        n_lanelets += 1

    out_dir = os.path.join(OUT_BASE, site)
    os.makedirs(out_dir, exist_ok=True)
    ET.ElementTree(out).write(os.path.join(out_dir, "lanelet2_map.osm"),
                              encoding="utf-8", xml_declaration=True)
    with open(os.path.join(out_dir, "map_projector_info.yaml"), "w") as f:
        f.write("projector_type: local\n")
    # tiny placeholder PCD (GNSS localization doesn't use it; map_loader wants a file)
    _write_dummy_pcd(os.path.join(out_dir, "pointcloud_map.pcd"), pcd_pts[:5000])

    print(f"==> {site}: {n_lanelets} lanelets, {gid.n} elements")
    print(f"    {out_dir}/lanelet2_map.osm")
    print(f"    {out_dir}/map_projector_info.yaml  (local)")
    print(f"    {out_dir}/pointcloud_map.pcd  (placeholder)")


def _write_dummy_pcd(path, pts):
    if not pts:
        pts = [(0.0, 0.0)]
    with open(path, "w") as f:
        f.write("# .PCD v0.7 - placeholder (GNSS localization)\n")
        f.write("VERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n")
        f.write(f"WIDTH {len(pts)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\n")
        f.write(f"POINTS {len(pts)}\nDATA ascii\n")
        for x, y in pts:
            f.write(f"{x:.2f} {y:.2f} 0.00\n")


if __name__ == "__main__":
    main()
