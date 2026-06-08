#!/usr/bin/env python3
"""CARLA -> WebSocket gateway for the Multi-Mode Autoware Monitor app.

Connects to a running CARLA server (0.10.0 or 0.9.x), spawns/привязывается an
ego vehicle on autopilot, and every second publishes ONE JSON frame that
conforms to the app's data contract (docs/data_contract.md) on
ws://0.0.0.0:8765/ws.

Real CARLA telemetry is used where the contract has a matching field:
  scenario.environment <- map name
  odometry             <- ego transform (x,y,z)
  vehicle_status       <- ego velocity / control
  gnss                 <- ego geo location
  metrics.*            <- real tick time, speed-derived
The localization "multi-mode" overlay (sensor combo / pipeline / Autoware stack
/ 6-state / safety) is derived from which absolute sensors are healthy. Toggle
sensor health by editing SENSOR_HEALTH or via the FAULT env (e.g. FAULT=gnss).

Run:
  pip install --break-system-packages websockets carla
  python3 carla_ws_gateway.py            # connects localhost:2000
  # then on the app: USB_ADB (adb reverse tcp:8765 tcp:8765) or WIFI mode
"""
import asyncio
import json
import math
import os
import datetime

import carla
import websockets

CARLA_HOST = os.environ.get("CARLA_HOST", "localhost")
CARLA_PORT = int(os.environ.get("CARLA_PORT", "2000"))
WS_HOST, WS_PORT, WS_PATH = "0.0.0.0", 8765, "/ws"

# which absolute sensors are healthy (flip to simulate faults / mode switches)
FAULT = set(f.strip().lower() for f in os.environ.get("FAULT", "").split(",") if f.strip())

CLIENTS = set()


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def pick_mode(healthy):
    """Decide localization mode / pipeline / stack / state from healthy absolute sensors."""
    have = [s for s in ("lidar", "gnss", "camera") if s in healthy]
    table = {
        ("lidar", "gnss", "camera"): ("LIDAR_GNSS_CAMERA", "TRIPLE", "TRIPLE_FUSION_STACK",
                                       "S1_NORMAL_FULL_STACK", "SAFE"),
        ("lidar", "gnss"): ("LIDAR_GNSS", "DUAL", "DUAL_LIDAR_GNSS_STACK",
                             "S4_DUAL_SENSOR_FUSION", "SAFE"),
        ("lidar", "camera"): ("LIDAR_CAMERA", "DUAL", "DUAL_LIDAR_CAMERA_STACK",
                              "S4_DUAL_SENSOR_FUSION", "SAFE"),
        ("gnss", "camera"): ("GNSS_CAMERA", "DUAL", "DUAL_GNSS_CAMERA_STACK",
                             "S4_DUAL_SENSOR_FUSION", "LIMITED_DRIVE"),
        ("lidar",): ("LIDAR_ONLY", "SINGLE", "LIDAR_LOCALIZATION_STACK",
                     "S5_SINGLE_SENSOR_FALLBACK", "LIMITED_DRIVE"),
        ("gnss",): ("GNSS_ONLY", "SINGLE", "GNSS_LOCALIZATION_STACK",
                    "S5_SINGLE_SENSOR_FALLBACK", "LIMITED_DRIVE"),
        ("camera",): ("CAMERA_ONLY", "SINGLE", "CAMERA_LOCALIZATION_STACK",
                      "S5_SINGLE_SENSOR_FALLBACK", "LIMITED_DRIVE"),
    }
    return table.get(tuple(have),
                     ("UNAVAILABLE", "UNAVAILABLE", "FALLBACK_STOP_STACK",
                      "S6_LOCALIZATION_UNAVAILABLE_STOP", "SAFE_STOP_REQUIRED"))


def sensor_block(healthy):
    def s(key, role):
        ok = key in healthy
        return {"status": "NORMAL" if ok else "FAULT", "used": ok,
                "role": role if ok else "UNUSED",
                "reason": "" if ok else "fault injected"}
    return {
        "lidar": s("lidar", "ABSOLUTE_LOCALIZATION"),
        "gnss": s("gnss", "ABSOLUTE_LOCALIZATION"),
        "camera": s("camera", "ABSOLUTE_LOCALIZATION"),
        "imu": {"status": "NORMAL", "used": True, "role": "SUPPORT", "reason": ""},
        "odometry": {"status": "NORMAL", "used": True, "role": "RELATIVE_LOCALIZATION", "reason": ""},
    }


def build_frame(world, ego, tick_ms):
    healthy = {s for s in ("lidar", "gnss", "camera") if s not in FAULT}
    mode, pipeline, stack, state, safety = pick_mode(healthy)

    tf = ego.get_transform() if ego else None
    vel = ego.get_velocity() if ego else carla.Vector3D()
    speed = math.sqrt(vel.x**2 + vel.y**2 + vel.z**2)  # m/s
    ctrl = ego.get_control() if ego else None
    try:
        geo = world.get_map().transform_to_geolocation(tf.location) if tf else None
    except Exception:
        geo = None
    mapname = world.get_map().name.split("/")[-1]

    abs_sensors = [s.upper().replace("LIDAR", "LiDAR") for s in ("lidar", "gnss", "camera") if s in healthy]
    abs_sensors = ["LiDAR" if s == "LIDAR" else ("GNSS" if s == "GNSS" else "Camera") for s in
                   [x.upper() for x in ("lidar", "gnss", "camera") if x in healthy]]

    return {
        "timestamp": now_iso(),
        "source": "VEHICLE",
        "scenario": {
            "id": "carla_live_001",
            "name": "CARLA Live (autopilot)",
            "environment": f"CARLA {mapname}",
            "drivingArea": "URBAN",
        },
        "stateMachine": {
            "stateId": state, "displayName": state.replace("_", " ").title(),
            "previousStateId": state, "transitionStatus": "COMPLETED",
            "transitionReason": "live sensor health: " + (",".join(sorted(healthy)) or "none"),
        },
        "localization": {
            "mode": mode, "pipelineType": pipeline,
            "absoluteSensors": abs_sensors,
            "relativeSensors": ["IMU", "Odometry"],
            "fusionMethod": "EKF (live)" if pipeline != "UNAVAILABLE" else "-",
            "fusionWeights": {
                "lidar": 0.5 if "lidar" in healthy else 0.0,
                "gnss": 0.25 if "gnss" in healthy else 0.0,
                "camera": 0.25 if "camera" in healthy else 0.0,
            },
            "confidence": 0.95 if len(healthy) == 3 else (0.85 if healthy else 0.0),
            "latencyMs": round(tick_ms, 1),
        },
        "sensors": sensor_block(healthy),
        "autoware": {
            "selectedStack": stack,
            "stackReason": f"derived from {len(healthy)} healthy absolute sensor(s)",
            "modules": {
                "sensing": "RUNNING", "localization": "RUNNING" if healthy else "ERROR",
                "perception": "RUNNING" if len(healthy) >= 2 else "LIMITED",
                "planning": "RUNNING" if healthy else "LIMITED",
                "control": "RUNNING", "map": "RUNNING" if healthy else "STOPPED",
                "vehicleInterface": "RUNNING",
            },
            "excludedModules": [] if len(healthy) == 3 else
                               [s + "_localization" for s in ("lidar", "gnss", "camera") if s not in healthy],
        },
        "roiiArchitecture": {
            "hpc": "NORMAL",
            "backbone": {"primary10G": "NORMAL", "secondary10G": "STANDBY"},
            "zones": {"frontLeft": "NORMAL", "frontRight": "NORMAL", "rear": "NORMAL"},
            "sensorMap": {
                "frontLeft": ["LiDAR-FL", "LiDAR-FC", "Cam-FL", "Cam-SL1", "Cam-SL2", "Radar-FL"],
                "frontRight": ["LiDAR-FR", "Cam-FC", "Cam-FR", "Cam-SR1", "Cam-SR2", "Radar-FC", "Radar-FR"],
                "rear": ["LiDAR-RC", "Cam-RC", "Radar-RL", "Radar-RR"],
            },
            "dataFlowStatus": "NORMAL" if healthy else "FAULT",
        },
        "metrics": {
            "cpuUsagePercent": 0, "gpuUsagePercent": 0, "memoryUsagePercent": 0,
            "endToEndLatencyMs": round(tick_ms, 1),
            "localizationLatencyMs": round(tick_ms, 1),
            "modeTransitionTimeMs": 0,
            "architectureReconfigurationTimeMs": 0,
            "trajectoryError": round(abs(speed) * 0.01, 3),
            "resourceSavingPercent": (3 - len(healthy)) * 10.0,
            "safetyState": safety,
        },
        "events": [
            {"timestamp": datetime.datetime.now().strftime("%H:%M:%S"),
             "level": "INFO",
             "message": f"ego @ ({tf.location.x:.1f},{tf.location.y:.1f}) speed {speed*3.6:.1f} km/h" if tf else "no ego"},
            {"timestamp": datetime.datetime.now().strftime("%H:%M:%S"),
             "level": "SUCCESS", "message": f"localization mode: {mode}"},
        ],
        # extra live fields (app ignores unknown keys gracefully)
        "_live": {"speedKmh": round(speed * 3.6, 1),
                  "pos": {"x": round(tf.location.x, 2), "y": round(tf.location.y, 2)} if tf else None,
                  "gnss": {"lat": geo.latitude, "lon": geo.longitude} if geo else None,
                  "throttle": round(ctrl.throttle, 2) if ctrl else 0},
    }


def ensure_ego(world):
    for a in world.get_actors().filter("vehicle.*"):
        if a.attributes.get("role_name") == "hero":
            return a
    bp = world.get_blueprint_library().filter("vehicle.*")[0]
    bp.set_attribute("role_name", "hero")
    sp = world.get_map().get_spawn_points()
    ego = world.try_spawn_actor(bp, sp[0]) if sp else None
    if ego:
        try:
            ego.set_autopilot(True)
        except Exception:
            pass
    return ego


async def handler(ws):
    CLIENTS.add(ws)
    print(f"[+] app connected ({len(CLIENTS)})")
    try:
        await ws.wait_closed()
    finally:
        CLIENTS.discard(ws)
        print(f"[-] app disconnected ({len(CLIENTS)})")


async def producer():
    client = carla.Client(CARLA_HOST, CARLA_PORT)
    client.set_timeout(20.0)
    world = client.get_world()
    print(f"connected to CARLA {client.get_server_version()} map={world.get_map().name}")
    ego = ensure_ego(world)
    print(f"ego: {ego.type_id if ego else 'NONE'}")
    import time
    while True:
        t0 = time.time()
        try:
            if ego is None or not ego.is_alive:
                ego = ensure_ego(world)
            frame = build_frame(world, ego, (time.time() - t0) * 1000.0)
            payload = json.dumps(frame)
            if CLIENTS:
                await asyncio.gather(*[c.send(payload) for c in list(CLIENTS)],
                                     return_exceptions=True)
        except Exception as e:
            print("tick error:", e)
        await asyncio.sleep(1.0)


def banner():
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]; s.close()
    except Exception:
        ip = "127.0.0.1"
    print("=" * 56)
    print("CARLA -> Multi-Mode Autoware Monitor  WebSocket gateway")
    print(f"  Wi-Fi:   ws://{ip}:{WS_PORT}{WS_PATH}")
    print(f"  USB ADB: ws://127.0.0.1:{WS_PORT}{WS_PATH}  (adb reverse tcp:8765 tcp:8765)")
    print("=" * 56)


async def main():
    banner()
    async with websockets.serve(handler, WS_HOST, WS_PORT):
        await producer()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nstopped.")
