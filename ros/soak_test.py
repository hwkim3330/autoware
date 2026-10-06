#!/usr/bin/env python3
"""Autonomous soak test through the gateway: drive, wait, record, repeat.

Each trip: send "drive", then watch until ARRIVED, a stall (speed < 0.3 m/s
for STALL_S while not arrived), or TRIP_MAX_S. Records per trip: outcome, time
to engage, distance, max speed, the worst NDT-vs-GNSS gap, and the last
cmdResult. Prints one line per trip and a summary; writes JSON lines to
--out.

    python3 soak_test.py --minutes 15 --out soak.jsonl
"""
import argparse
import asyncio
import json
import math
import time

import websockets

STALL_S = 25.0
TRIP_MAX_S = 180.0
ENGAGE_MAX_S = 60.0


async def run(url, minutes, out):
    end = time.time() + minutes * 60
    trips = []
    async with websockets.connect(url, max_size=None) as ws:
        async def frames():
            while True:
                d = json.loads(await ws.recv())
                if "ego" in d:
                    yield d

        it = frames()
        n = 0
        while time.time() < end:
            n += 1
            await ws.send(json.dumps({"cmd": "drive"}))
            t0 = time.time()
            engaged_at = None
            dist = vmax = gapmax = 0.0
            last_xy = None
            last_move = t0
            outcome = "timeout"
            res = ""
            async for d in it:
                now = time.time()
                op = (d.get("operationMode") or {}).get("mode")
                rs = (d.get("route") or {}).get("state")
                e = d["ego"]
                v = abs(e.get("speedKmh") or 0.0) / 3.6
                res = d.get("cmdResult") or res
                gap = (d.get("multimode") or {}).get("gapM")
                if gap is not None:
                    gapmax = max(gapmax, gap)
                if op == "AUTONOMOUS" and engaged_at is None:
                    engaged_at = now - t0
                if last_xy is not None:
                    dist += math.hypot(e["x"] - last_xy[0], e["y"] - last_xy[1])
                last_xy = (e["x"], e["y"])
                vmax = max(vmax, v)
                if v > 0.3:
                    last_move = now
                if engaged_at is None and now - t0 > ENGAGE_MAX_S:
                    outcome = "engage_fail"; break
                if rs == "ARRIVED" and now - t0 > 5:
                    outcome = "arrived"; break
                if engaged_at is not None and now - last_move > STALL_S:
                    outcome = "stall"; break
                if now - t0 > TRIP_MAX_S:
                    break
            rec = {"trip": n, "outcome": outcome, "engage_s": None if engaged_at is None else round(engaged_at, 1),
                   "dist_m": round(dist, 1), "vmax_kmh": round(vmax * 3.6, 1), "gap_max_m": round(gapmax, 2),
                   "dur_s": round(time.time() - t0, 1), "last_result": res[:60]}
            trips.append(rec)
            print(json.dumps(rec, ensure_ascii=False), flush=True)
            if out:
                with open(out, "a") as f:
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if outcome in ("stall", "engage_fail", "timeout"):
                # recover the way a demo operator would: back to the spawn
                await ws.send(json.dumps({"cmd": "respawn"}))
                await asyncio.sleep(15)
    ok = sum(t["outcome"] == "arrived" for t in trips)
    print(f"SUMMARY trips={len(trips)} arrived={ok} "
          f"stall={sum(t['outcome'] == 'stall' for t in trips)} "
          f"engage_fail={sum(t['outcome'] == 'engage_fail' for t in trips)} "
          f"timeout={sum(t['outcome'] == 'timeout' for t in trips)} "
          f"dist={sum(t['dist_m'] for t in trips):.0f} m", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8765/ws")
    ap.add_argument("--minutes", type=float, default=15)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    asyncio.run(run(a.url, a.minutes, a.out))


if __name__ == "__main__":
    main()
