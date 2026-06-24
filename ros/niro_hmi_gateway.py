#!/usr/bin/env python3
"""
Niro HMI Gateway — READ-ONLY ROS <-> WebSocket bridge for external Android HMI.

Streams the live Niro real-vehicle (or CARLA-sim) state to one or more Android
clients as JSON. It SUBSCRIBES ROS topics and SENDS status frames; it NEVER
publishes a control topic, never touches CARLA, and never processes commands.

It does NOT modify or share state with ros/ros_ws_gateway.py (the CARLA control
path), and uses a different default port for the carla_niro profile (8766) so
both can run side by side.

Design mirrors the proven ros_ws_gateway.py patterns:
  - websockets server with a multi-client broadcast set,
  - ROS spun in a MultiThreadedExecutor on a background thread,
  - an asyncio WALL-CLOCK broadcast loop (NOT a ROS timer) — so it keeps
    broadcasting even under use_sim_time with no /clock (the bug that froze the
    old gateway's timers).

Usage:
    python3 niro_hmi_gateway.py <profile>
        profile = carla_niro | ssu_niro | generic_autoware
"""
import asyncio
import datetime
import json
import os
import sys
import threading
import time

import rclpy
from rclpy.node import Node
from rclpy.executors import MultiThreadedExecutor
import websockets
import yaml

# adapters live alongside this file under hmi_adapters/; add both this dir and
# the package dir to sys.path so the plain-module imports work when run directly.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "hmi_adapters"))

from hmi_state import HmiState  # noqa: E402

PROFILES = ("carla_niro", "ssu_niro", "generic_autoware")
BROADCAST_HZ = 10.0


def load_config(profile):
    path = os.path.join(_HERE, "..", "config", "hmi", f"{profile}.yaml")
    path = os.path.abspath(path)
    with open(path) as f:
        return yaml.safe_load(f), path


def make_adapter(profile, node, cfg, state):
    if profile == "carla_niro":
        from carla_niro_adapter import CarlaNiroAdapter
        return CarlaNiroAdapter(node, cfg, state)
    if profile == "ssu_niro":
        from ssu_niro_adapter import SsuNiroAdapter
        return SsuNiroAdapter(node, cfg, state)
    if profile == "generic_autoware":
        from generic_autoware_adapter import GenericAutowareAdapter
        return GenericAutowareAdapter(node, cfg, state)
    raise ValueError(f"unknown profile: {profile}")


# ---- shared runtime state ---------------------------------------------------
CLIENTS = set()
STATE = HmiState()
CFG = {}
PROFILE = ""
SOURCE = ""
NODE = None
START_T = time.monotonic()


def _timeouts():
    t = CFG.get("timeouts", {}) or {}
    return {
        "localization_sec": float(t.get("localization_sec", 1.0)),
        "vehicle_sec": float(t.get("vehicle_sec", 1.0)),
        "trajectory_sec": float(t.get("trajectory_sec", 3.0)),
        "system_sec": float(t.get("system_sec", 3.0)),
    }


# which topic-keys count toward each timeout class
_TIMEOUT_KEYS = {
    "localization_sec": ("multimode.mode_topic", "multimode.status_topic",
                         "multimode.fused_pose_topic"),
    "vehicle_sec": ("multimode.fused_twist_topic", "autoware.odometry_topic",
                    "vehicle.velocity_topic", "vehicle.steering_topic"),
    "trajectory_sec": ("autoware.trajectory_topic",),
    "system_sec": ("autoware.operation_mode_topic", "autoware.route_state_topic",
                   "autoware.mrm_state_topic"),
}


def compute_stale(now):
    """Data is stale if every topic that has EVER updated is older than its
    timeout. If nothing has ever updated, treat as stale (no data yet)."""
    timeouts = _timeouts()
    lut = STATE.last_update_times
    if not lut:
        return True
    any_fresh = False
    for cls, keys in _TIMEOUT_KEYS.items():
        limit = timeouts[cls]
        for k in keys:
            if k in lut and (now - lut[k]) <= limit:
                any_fresh = True
    return not any_fresh


def build_capabilities():
    # ALWAYS read-only in this phase, regardless of command.enabled (false).
    return {
        "readOnly": True,
        "setRoute": False,
        "engage": False,
        "stop": False,
        "mrm": False,
        "teleop": False,
        "faultInjection": False,
    }


def build_frame():
    global STATE
    now = time.monotonic()
    STATE.sequence += 1
    STATE.timestamp = datetime.datetime.now(
        datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    STATE.ros_connected = (NODE is not None) and rclpy.ok()
    STATE.data_stale = compute_stale(now)
    payload = STATE.to_json(build_capabilities(), PROFILE, SOURCE,
                            STATE.sequence)
    # downsample trajectory to <=100 points (defensive; adapters already cap)
    traj = STATE.trajectory or []
    if len(traj) > 100:
        step = max(1, len(traj) // 100)
        traj = traj[::step]
    payload["trajectory"] = traj
    return payload


# ---- websocket handler (read-only) ------------------------------------------
async def handler(ws):
    CLIENTS.add(ws)
    print(f"[+] HMI client connected ({len(CLIENTS)})")
    try:
        async for msg in ws:
            # READ-ONLY: ignore inbound commands; just log them.
            print(f"[ignored inbound] {str(msg)[:120]}")
    except Exception:
        pass
    finally:
        CLIENTS.discard(ws)
        print(f"[-] HMI client disconnected ({len(CLIENTS)})")


async def broadcast_loop():
    """Asyncio WALL-CLOCK broadcast at ~BROADCAST_HZ. Independent of ROS time so
    it keeps running with use_sim_time and no /clock, and with zero clients."""
    period = 1.0 / BROADCAST_HZ
    while True:
        try:
            payload = json.dumps(build_frame())
            if CLIENTS:
                results = await asyncio.gather(
                    *[c.send(payload) for c in list(CLIENTS)],
                    return_exceptions=True)
                for c, r in zip(list(CLIENTS), results):
                    if isinstance(r, Exception):
                        CLIENTS.discard(c)
        except Exception as e:
            print("broadcast error:", e)
        await asyncio.sleep(period)


def spin_ros(node):
    ex = MultiThreadedExecutor(num_threads=2)
    ex.add_node(node)
    ex.spin()


async def main():
    global CFG, PROFILE, SOURCE, NODE

    profile = sys.argv[1] if len(sys.argv) > 1 else "carla_niro"
    if profile not in PROFILES:
        print(f"unknown profile '{profile}'. choices: {', '.join(PROFILES)}")
        sys.exit(2)

    CFG, cfg_path = load_config(profile)
    PROFILE = CFG.get("profile", profile)
    SOURCE = CFG.get("source", "UNKNOWN")
    net = CFG.get("network", {}) or {}
    host = net.get("host", "0.0.0.0")
    port = int(net.get("port", 8765))
    path = net.get("path", "/ws")

    rclpy.init()
    NODE = Node("niro_hmi_gateway")
    STATE.profile = PROFILE
    STATE.source = SOURCE

    adapter = make_adapter(profile, NODE, CFG, STATE)
    adapter.subscribe()

    threading.Thread(target=spin_ros, args=(NODE,), daemon=True).start()

    print("=" * 60)
    print(f"Niro HMI Gateway (READ-ONLY)  profile={PROFILE} source={SOURCE}")
    print(f"  config: {cfg_path}")
    print(f"  ws://<host>:{port}{path}   (USB: adb reverse tcp:{port} tcp:{port})")
    print(f"  command processing: DISABLED (read-only)")
    print("=" * 60)

    async with websockets.serve(handler, host, port):
        await broadcast_loop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
