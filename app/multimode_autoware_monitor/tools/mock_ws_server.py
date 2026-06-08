#!/usr/bin/env python3
"""Mock WebSocket server for Multi-Mode Autoware Monitor.

Serves the 7 reference scenarios (tools/sample_messages/*.json) in order, one
per second, to every connected client on ws://0.0.0.0:8765/ws.

Run:
    cd tools
    python3 -m venv .venv && source .venv/bin/activate
    pip install websockets
    python mock_ws_server.py

Then point the Flutter app's Settings at:
    Wi-Fi:    ws://<this-PC-IP>:8765/ws
    USB ADB:  ws://127.0.0.1:8765/ws   (after: adb reverse tcp:8765 tcp:8765)
"""
import asyncio
import json
import os
import socket
import datetime
from pathlib import Path

try:
    import websockets
except ImportError:
    raise SystemExit("Missing dependency. Run: pip install websockets")

HOST = "0.0.0.0"
PORT = 8765
PATH = "/ws"
INTERVAL_SEC = 1.0

SAMPLE_DIR = Path(__file__).parent / "sample_messages"
SAMPLE_ORDER = [
    "triple_fusion_normal.json",
    "urban_roi_ndt.json",
    "rural_minimum.json",
    "dual_lidar_gnss.json",
    "gnss_unavailable_lidar_fallback.json",
    "lidar_degraded_gnss_camera_fallback.json",
    "localization_unavailable_stop.json",
]


def load_samples():
    samples = []
    for name in SAMPLE_ORDER:
        p = SAMPLE_DIR / name
        if p.exists():
            with open(p, "r", encoding="utf-8") as f:
                samples.append(json.load(f))
        else:
            print(f"[warn] sample missing: {p}")
    if not samples:
        raise SystemExit(f"No sample messages found in {SAMPLE_DIR}")
    return samples


def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


SAMPLES = load_samples()
CLIENTS = set()


async def producer():
    """Broadcast one scenario per second, cycling forever."""
    i = 0
    while True:
        msg = dict(SAMPLES[i % len(SAMPLES)])
        i += 1
        # stamp a fresh timestamp + mark source as WIFI
        msg["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        msg["source"] = "WIFI"
        payload = json.dumps(msg)
        if CLIENTS:
            await asyncio.gather(
                *[_safe_send(ws, payload) for ws in list(CLIENTS)],
                return_exceptions=True,
            )
        await asyncio.sleep(INTERVAL_SEC)


async def _safe_send(ws, payload):
    try:
        await ws.send(payload)
    except Exception:
        CLIENTS.discard(ws)


async def handler(websocket):
    # websockets>=11 passes only the connection; path is on the object.
    path = getattr(websocket, "path", PATH)
    if path not in (PATH, "/", ""):
        await websocket.close(code=1008, reason="unknown path")
        return
    CLIENTS.add(websocket)
    print(f"[+] client connected ({len(CLIENTS)} total)")
    try:
        await websocket.wait_closed()
    finally:
        CLIENTS.discard(websocket)
        print(f"[-] client disconnected ({len(CLIENTS)} total)")


def banner():
    ip = local_ip()
    print("=" * 56)
    print("Multi-Mode Autoware Monitor — Mock WebSocket Server")
    print("=" * 56)
    print("Server running on:")
    print(f"  Local:  ws://127.0.0.1:{PORT}{PATH}")
    print(f"  Wi-Fi:  ws://{ip}:{PORT}{PATH}")
    print()
    print("For USB ADB mode:")
    print(f"  adb reverse tcp:{PORT} tcp:{PORT}")
    print("  Use this URL in the Android app:")
    print(f"  ws://127.0.0.1:{PORT}{PATH}")
    print()
    print("For Wi-Fi mode:")
    print("  Use this URL in the Android app:")
    print(f"  ws://{ip}:{PORT}{PATH}")
    print("=" * 56)
    print(f"Cycling {len(SAMPLES)} scenarios every {INTERVAL_SEC:.0f}s. Ctrl-C to stop.")


async def main():
    banner()
    async with websockets.serve(handler, HOST, PORT):
        await producer()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nstopped.")
