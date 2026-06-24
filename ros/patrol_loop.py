#!/usr/bin/env python3
"""Continuous autonomous patrol: keep the ego driving forever.

Connects to the gateway, issues "drive" (gateway picks a goal ahead, engages),
and re-issues whenever the route finishes (ARRIVED), is cleared (UNSET), or the
ego is stuck (speed ~0 for too long while not arrived -- a rejected/idle route).
Prints a one-line status whenever it changes. Run inside the container:
    python3 patrol_loop.py            # ws://127.0.0.1:8765/ws
Ctrl-C to stop.
"""
import asyncio, json, sys, time
import websockets

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:8765/ws"
STUCK_S = 20.0      # speed<0.3 this long while not ARRIVED -> re-drive
GRACE_S = 8.0       # after issuing drive, don't re-issue for this long


async def main():
    trips = 0
    async with websockets.connect(URL) as ws:
        async def drive():
            nonlocal trips, last_cmd
            trips += 1
            await ws.send(json.dumps({"cmd": "drive"}))
            last_cmd = time.time()
            print(f"[patrol] trip #{trips} -> drive", flush=True)
        last_cmd = 0.0
        last_move = time.time()
        await drive()
        prev = ""
        while True:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
            except Exception:
                continue
            if m.get("type") in ("lanes", "camera", "view"):
                continue   # not a state frame
            e = m.get("ego", {}); r = m.get("route", {}); op = m.get("operationMode", {})
            spd = e.get("speedKmh", 0.0); rstate = r.get("state"); now = time.time()
            nobj = len(m.get("objects", []))
            if spd > 0.5:
                last_move = now
            line = (f"route={rstate} traj={r.get('trajPoints',0)} "
                    f"mode={op.get('mode')} spd={spd:.1f} objs={nobj}")
            if line != prev:
                print(f"[patrol] {line}", flush=True); prev = line
            if now - last_cmd < GRACE_S:
                continue
            arrived = rstate == "ARRIVED"
            unset = rstate in ("UNSET", "UNKNOWN")
            stuck = (now - last_move) > STUCK_S
            if arrived or unset or stuck:
                why = "ARRIVED" if arrived else ("UNSET" if unset else "STUCK")
                last_move = now
                # Always re-drive (pick a fresh goal ahead). NOT respawn: re-seeding
                # the pose makes ndt_scan_matcher transiently drop lock in CARLA.
                # A stuck arrival point usually clears when a new forward goal is
                # chosen, so just keep issuing drive.
                print(f"[patrol] re-drive ({why})", flush=True)
                await drive()


asyncio.run(main())
