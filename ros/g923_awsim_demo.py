#!/usr/bin/env python3
"""G923 wheel + pedals <-> Autoware (AWSIM or CARLA) through the tablet gateway.

AUTONOMOUS  the wheel is a servo that follows the vehicle's real steering angle
            (gateway frame `vehicle.steerDeg` x STEER_RATIO), so it turns by itself.
MANUAL      the wheel steers, the pedals drive: throttle raises and brake lowers a
            target speed that the gateway's speed loop tracks. Paddles pick the
            gear (right = D, left = R) since there is no shifter.

Switching, like a real car:
    X / cross button      engage AUTONOMOUS (gateway "drive": route ahead + engage)
    brake pedal           take over -> MANUAL
    turn the wheel        take over -> MANUAL (25 deg off the autopilot for 0.3 s)
    Options button        STOP (hold position)

Runs on the host (needs the wheel's hidraw, so root):
    sudo python3 g923_awsim_demo.py [ws://127.0.0.1:8765/ws]
"""
import asyncio
import glob
import json
import math
import os
import sys
import time

import evdev
import websockets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import g923_wheel  # noqa: E402

E = evdev.ecodes
URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:8765/ws"
STEER_RATIO = 12.0          # wheel deg per tire deg (900 deg lock -> +-37 deg tire)
MAX_WHEEL_DEG = 440.0
VMAX = 12.0                 # m/s manual forward cap (~43 km/h)
VMAX_REV = 3.0
ACCEL_RATE = 3.0            # m/s per second at full throttle
BRAKE_RATE = 8.0            # m/s per second at full brake
BRAKE_TAKEOVER = 0.25       # brake travel that counts as a takeover
OVERRIDE_DEG = 25.0         # wheel this far off the autopilot's angle ...
OVERRIDE_S = 0.3            # ... for this long = the driver is steering

# G29-class button layout in hid-generic order
BTN_CROSS, BTN_PADDLE_R, BTN_PADDLE_L, BTN_OPTIONS = E.BTN_TRIGGER, E.BTN_TOP2, E.BTN_PINKIE, E.BTN_BASE4


def pedal(v):  # 255 = released, 0 = floored
    return max(0.0, min(1.0, (255 - v) / 255.0))


class Demo:
    def __init__(self):
        g923_wheel.switch_mode()
        self.w = g923_wheel.Wheel()
        self.ev = self.w.ev
        self.mode = "MANUAL"          # until the vehicle reports AUTONOMOUS
        self.gear = 1                 # +1 D, -1 R
        self.v_target = 0.0
        self.throttle = self.brake = 0.0
        self.ws = None
        self.steer_deg_vehicle = 0.0
        self.op = "?"
        self.speed_ms = 0.0
        self.w.target = None
        self.w.autocenter(True)

    def set_mode(self, mode):
        if mode == self.mode:
            return
        self.mode = mode
        if mode == "AUTONOMOUS":
            self.w.autocenter(False)
            self.w.target = 0.0
        else:
            self.w.target = None
            self.w.autocenter(True)
            # like a Tesla disengaging: hand over at the current speed, not a stop;
            # the brake pedal (if that was the takeover) then slows it as usual
            self.v_target = abs(self.speed_ms)
        print(f"[mode] {mode}", flush=True)

    async def send(self, obj):
        if self.ws is not None:
            try:
                await self.ws.send(json.dumps(obj))
            except Exception:
                pass

    async def read_inputs(self):
        loop = asyncio.get_running_loop()
        fd = self.ev.fd
        q = asyncio.Queue()
        loop.add_reader(fd, lambda: [q.put_nowait(e) for e in self.ev.read()])
        while True:
            e = await q.get()
            if e.type == E.EV_ABS:
                # G923 native mode, measured: Z = accelerator, RZ = brake, Y = clutch (unused)
                if e.code == E.ABS_Z:
                    self.throttle = pedal(e.value)
                elif e.code == E.ABS_RZ:
                    self.brake = pedal(e.value)
                    if self.mode == "AUTONOMOUS" and self.brake > BRAKE_TAKEOVER:
                        self.set_mode("MANUAL")
                        print("[takeover] brake", flush=True)
            elif e.type == E.EV_KEY and e.value == 1:
                if e.code == BTN_CROSS:
                    print("[cmd] drive (engage autonomous)", flush=True)
                    await self.send({"cmd": "drive"})
                # Paddles always shift and zero the target speed. Gating R on
                # v_target refused it after a crash: the car was stuck at 0 m/s
                # while the held throttle kept the *target* high.
                elif e.code == BTN_PADDLE_R:
                    self.gear, self.v_target = 1, 0.0; print("[gear] D", flush=True)
                elif e.code == BTN_PADDLE_L:
                    self.gear, self.v_target = -1, 0.0; print("[gear] R", flush=True)
                elif e.code == BTN_OPTIONS:
                    await self.send({"cmd": "stop"}); self.set_mode("MANUAL")

    async def manual_loop(self):
        dt = 0.05
        while True:
            await asyncio.sleep(dt)
            if self.mode != "MANUAL":
                continue
            vmax = VMAX if self.gear > 0 else VMAX_REV
            self.v_target += (self.throttle * ACCEL_RATE - self.brake * BRAKE_RATE) * dt
            self.v_target = max(0.0, min(vmax, self.v_target))
            if self.throttle < 0.02 and self.brake < 0.02:
                self.v_target = max(0.0, self.v_target - 0.5 * dt)   # coast down
            # wheel angle + = left, Autoware steering_tire_angle + = left (rad)
            tire = math.radians(self.w.angle() / STEER_RATIO)
            if self.throttle > 0.02 or self.brake > 0.02 or self.v_target > 0.05:
                await self.send({"cmd": "teleop", "v": self.gear * self.v_target,
                                 "steer": max(-0.6, min(0.6, tire))})

    async def gateway(self):
        while True:
            try:
                async with websockets.connect(URL, max_size=None) as ws:
                    self.ws = ws
                    print(f"[gw] connected {URL}", flush=True)
                    async for msg in ws:
                        d = json.loads(msg)
                        if d.get("type") == "lanes":
                            continue
                        om = d.get("operationMode") or {}
                        op = om.get("mode") if isinstance(om, dict) else om
                        if op != self.op:
                            self.op = op
                            print(f"[vehicle] operation mode {op}", flush=True)
                        if op == "AUTONOMOUS" and self.brake < BRAKE_TAKEOVER:
                            self.set_mode("AUTONOMOUS")
                        self.speed_ms = float((d.get("ego") or {}).get("speedKmh") or 0.0) / 3.6
                        veh = d.get("vehicle") or {}
                        self.steer_deg_vehicle = float(veh.get("steerDeg") or 0.0)
                        if self.mode == "AUTONOMOUS":
                            wd = self.steer_deg_vehicle * STEER_RATIO
                            self.w.target = max(-MAX_WHEEL_DEG, min(MAX_WHEEL_DEG, wd))
            except Exception as ex:
                self.ws = None
                print(f"[gw] {ex!r}; retrying", flush=True)
                await asyncio.sleep(2)

    async def override_watch(self):
        """Tesla-style: turning the wheel against the autopilot disengages it."""
        held = 0.0
        while True:
            await asyncio.sleep(0.05)
            ref = self.w.ref_angle()
            if self.mode != "AUTONOMOUS" or ref is None:
                held = 0.0
                continue
            dev = abs(self.w.angle() - ref)
            held = held + 0.05 if dev > OVERRIDE_DEG else 0.0
            if held >= OVERRIDE_S:
                print(f"[takeover] steering override ({dev:.0f} deg off the autopilot)", flush=True)
                self.set_mode("MANUAL")
                held = 0.0

    async def status(self):
        while True:
            await asyncio.sleep(2)
            print(f"[st] {self.mode:10s} op={self.op} gear={'D' if self.gear > 0 else 'R'} "
                  f"v_tgt={self.v_target:4.1f} thr={self.throttle:.2f} brk={self.brake:.2f} "
                  f"wheel={self.w.angle():+6.1f} veh_steer={self.steer_deg_vehicle:+5.1f}", flush=True)

    async def run(self):
        try:
            await asyncio.gather(self.read_inputs(), self.manual_loop(), self.gateway(),
                                 self.override_watch(), self.status())
        finally:
            self.w.close()


if __name__ == "__main__":
    try:
        asyncio.run(Demo().run())
    except KeyboardInterrupt:
        pass
