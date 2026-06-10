#!/usr/bin/env python3
"""Send a drive command to the gateway and monitor the autonomous run.

Usage (inside container):
    python3 drive_monitor.py drive            # gateway picks a goal ahead
    python3 drive_monitor.py goto <x> <y>     # tap-to-go to a map point
Prints route/traj/mode/speed/pose for ~45 s so we can see the ego actually move.
"""
import asyncio, json, sys, time
import websockets

URL = "ws://127.0.0.1:8765/ws"


async def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "drive"
    msg = {"cmd": cmd}
    if cmd == "goto":
        msg["x"] = float(sys.argv[2]); msg["y"] = float(sys.argv[3])
    async with websockets.connect(URL) as ws:
        await ws.send(json.dumps(msg))
        t0 = time.time()
        last = ""
        while time.time() - t0 < 50:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
            except Exception:
                continue
            if m.get("type") == "lanes":
                print("lanes:", len(m.get("pts", [])))
                continue
            e = m.get("ego", {})
            r = m.get("route", {})
            op = m.get("operationMode", {})
            line = (f"{int(time.time()-t0):2d}s route={r.get('state')} "
                    f"traj={r.get('trajPoints',0)} mode={op.get('mode')} "
                    f"avail={op.get('autonomousAvailable')} "
                    f"spd={e.get('speedKmh',0):.1f}km/h "
                    f"ego=({e.get('x',0):.1f},{e.get('y',0):.1f}) "
                    f"{m.get('cmdResult','')}")
            if line[3:] != last:
                print(line, flush=True)
                last = line[3:]


asyncio.run(main())
