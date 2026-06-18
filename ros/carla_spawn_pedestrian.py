#!/usr/bin/env python3
# Spawn a pedestrian ~8m in front of the ego (in the front-camera FOV) so we can
# verify YOLOX detects it. Usage: python3 carla_spawn_pedestrian.py [dist] [lat]
import sys, math, carla
dist = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
lat  = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
c = carla.Client("localhost", 2000); c.set_timeout(10.0); w = c.get_world()
try: w.wait_for_tick(5.0)
except Exception: pass
ego = next((a for a in w.get_actors().filter("vehicle.*")
            if a.attributes.get("role_name") == "ego_vehicle"), None)
if ego is None:
    print("NO EGO", flush=True); raise SystemExit(1)
tf = ego.get_transform(); fwd = tf.get_forward_vector(); rgt = tf.get_right_vector()
loc = carla.Location(
    x=tf.location.x + fwd.x*dist + rgt.x*lat,
    y=tf.location.y + fwd.y*dist + rgt.y*lat,
    z=tf.location.z + 1.0)
bp = w.get_blueprint_library().filter("walker.pedestrian.*")[0]
yaw = math.degrees(math.atan2(-fwd.y, -fwd.x))  # face the ego
ped = w.try_spawn_actor(bp, carla.Transform(loc, carla.Rotation(yaw=yaw)))
if ped is None:
    print(f"spawn failed at {loc}", flush=True); raise SystemExit(1)
print(f"pedestrian {ped.id} spawned {dist}m ahead, lat {lat}m at "
      f"({loc.x:.1f},{loc.y:.1f},{loc.z:.1f})", flush=True)
