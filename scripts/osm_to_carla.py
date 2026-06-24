#!/usr/bin/env python3
"""OSM (real location) -> OpenDRIVE -> CARLA world.

Step 1 of the real-map pipeline (숭실대/판교/K-City). Downloads OpenStreetMap data
for a named site via the Overpass API, converts it to OpenDRIVE with CARLA's
Osm2Odr (a STATIC converter -- no running CARLA needed), and optionally loads it
into a running CARLA as a generated OpenDRIVE world.

The .xodr it writes is also the input for the Autoware side (OpenDRIVE -> lanelet2
+ GNSS localization), handled by a separate step.

Usage:
    python3 osm_to_carla.py soongsil                 # download + convert -> .xodr
    python3 osm_to_carla.py pangyo --radius 800
    python3 osm_to_carla.py soongsil --load          # also push into running CARLA
    python3 osm_to_carla.py --lat 37.4965 --lon 126.9573 --name mysite
"""
import argparse
import os
import sys
import urllib.request

# CARLA's Osm2Odr uses PROJ; point it at a proj.db that exists on this box
# (otherwise: "proj_create: Cannot find proj.db" -> "Could not build projection!").
for _p in ("/usr/local/lib/python3.12/dist-packages/pyproj/proj_dir/share/proj",
           "/usr/share/proj", "/snap/gazebo/48/usr/share/proj"):
    if os.path.exists(os.path.join(_p, "proj.db")):
        os.environ.setdefault("PROJ_LIB", _p)
        os.environ.setdefault("PROJ_DATA", _p)
        break

# Known sites (lat, lon) -- the Niro spec's Soongsil University + the others asked for.
SITES = {
    "soongsil": (37.4963, 126.9573, "숭실대학교"),
    "pangyo":   (37.3947, 127.1112, "판교"),
    "kcity":    (37.2410, 126.7720, "K-City (자율주행 실험도시)"),
}

OUT_DIR = os.path.expanduser("~/autoware_map/osm")


def download_osm(lat, lon, radius_m):
    """Fetch OSM XML for a bbox of +-radius around (lat,lon) via Overpass."""
    # rough deg-per-meter at this latitude
    dlat = radius_m / 111320.0
    import math
    dlon = radius_m / (111320.0 * math.cos(math.radians(lat)))
    s, n, w, e = lat - dlat, lat + dlat, lon - dlon, lon + dlon
    # ways with a highway tag + their nodes (recurse down), plus the bbox
    query = (
        "[out:xml][timeout:60];"
        f"(way[\"highway\"]({s},{w},{n},{e}););"
        "(._;>;);out body;"
    )
    for ep in ("https://overpass-api.de/api/interpreter",
               "https://overpass.kumi.systems/api/interpreter"):
        try:
            print(f"  Overpass: {ep}")
            req = urllib.request.Request(ep, data=query.encode("utf-8"),
                                         headers={"User-Agent": "niro-osm/1.0"})
            with urllib.request.urlopen(req, timeout=90) as r:
                data = r.read().decode("utf-8")
            if "<way" in data:
                return data
            print("    (no ways returned, trying next endpoint)")
        except Exception as ex:
            print(f"    failed: {ex}")
    raise RuntimeError("Overpass download failed on all endpoints")


def osm_to_xodr(osm_str, lat, lon):
    """Convert OSM XML -> OpenDRIVE string via CARLA's static Osm2Odr.

    Uses a transverse-mercator projection CENTERED on the site (lat,lon) so the
    generated map is in local meters around (0,0) -- matching Autoware's
    `projector_type: local`."""
    import carla
    settings = carla.Osm2OdrSettings()
    settings.use_offsets = False
    # local ENU-ish meters centered on the site origin
    settings.proj_string = (
        f"+proj=tmerc +lat_0={lat} +lon_0={lon} +k=1 +x_0=0 +y_0=0 "
        "+ellps=WGS84 +datum=WGS84 +units=m +no_defs")
    # keep sidewalks/center off the road network simple + drivable
    try:
        settings.generate_traffic_lights = True
        settings.all_junctions_with_traffic_lights = False
    except Exception:
        pass
    return carla.Osm2Odr.convert(osm_str, settings)


def load_into_carla(xodr_str, host="127.0.0.1", port=2000):
    import carla
    client = carla.Client(host, port)
    client.set_timeout(60.0)
    params = carla.OpendriveGenerationParameters(
        vertex_distance=2.0, max_road_length=200.0, wall_height=0.0,
        additional_width=0.6, smooth_junctions=True, enable_mesh_visibility=True)
    print("  loading generated OpenDRIVE world into CARLA...")
    client.generate_opendrive_world(xodr_str, params)
    print("  CARLA world replaced with the OpenDRIVE map.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("site", nargs="?", help="soongsil | pangyo | kcity")
    ap.add_argument("--lat", type=float); ap.add_argument("--lon", type=float)
    ap.add_argument("--name", default=None)
    ap.add_argument("--radius", type=int, default=600, help="half-extent meters")
    ap.add_argument("--load", action="store_true", help="push into running CARLA")
    a = ap.parse_args()

    if a.site and a.site in SITES:
        lat, lon, label = SITES[a.site]; name = a.site
    elif a.lat and a.lon:
        lat, lon, label, name = a.lat, a.lon, a.name or "mysite", a.name or "mysite"
    else:
        print("specify a known site", list(SITES), "or --lat --lon --name"); sys.exit(1)

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"==> {name} ({label})  ({lat}, {lon})  +-{a.radius} m")
    osm = download_osm(lat, lon, a.radius)
    osm_path = os.path.join(OUT_DIR, f"{name}.osm")
    with open(osm_path, "w") as f:
        f.write(osm)
    print(f"  OSM saved: {osm_path} ({len(osm)//1024} KB)")

    print("  converting OSM -> OpenDRIVE (carla.Osm2Odr)...")
    xodr = osm_to_xodr(osm, lat, lon)
    xodr_path = os.path.join(OUT_DIR, f"{name}.xodr")
    with open(xodr_path, "w") as f:
        f.write(xodr)
    nroads = xodr.count("<road ")
    print(f"  OpenDRIVE saved: {xodr_path} ({len(xodr)//1024} KB, {nroads} roads)")
    # stash the geo origin for the Autoware projector/datum step
    with open(os.path.join(OUT_DIR, f"{name}.origin"), "w") as f:
        f.write(f"{lat} {lon}\n")

    if a.load:
        load_into_carla(xodr)
    print("DONE.")


if __name__ == "__main__":
    main()
