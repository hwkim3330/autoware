#!/usr/bin/env python3
"""Drive a Logitech G923 (PlayStation/PC, 046d:c267) as a position servo from userspace.

The stock 6.8 kernel binds this wheel to hid-generic: no force feedback. Two
steps make it controllable without a kernel module:

1. Mode switch. Out of the box the wheel enumerates in PS-compatibility mode
   (c267, 8-bit axis). new-lg4ff switches it with output report 0x30
   `f8 09 07 01 01 00 00` sent as a SET_REPORT control transfer; a plain
   hidraw write() goes to the interrupt endpoint and is ignored, so this uses
   HIDIOCSOUTPUT. The wheel re-enumerates as c266 (16-bit axis) and runs its
   lock-to-lock self-calibration.
2. Force. In c266 mode the wheel accepts the classic Logitech 7-byte commands
   (unnumbered report). A constant force (slot 1) is updated at ~100 Hz from a
   PD loop on the measured position, which turns the wheel into a servo that
   follows a commanded angle.

Usage (needs root or a udev rule for /dev/hidraw*):
    g923_wheel.py switch            # c267 -> c266, once per plug-in
    g923_wheel.py test              # small right/left/centre sweep
    g923_wheel.py stdin             # follow angles (deg, + = left) read from stdin
"""
import fcntl
import glob
import os
import sys
import threading
import time

import evdev

RANGE_DEG = 900.0  # lock to lock


def _ioc(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr


def _hidraw(pid):
    for h in sorted(glob.glob('/sys/class/hidraw/hidraw*')):
        ue = open(h + '/device/uevent').read()
        if pid in ue and h and os.path.basename(os.path.realpath(h + '/device/..')).endswith(':1.0'):
            return '/dev/' + os.path.basename(h)
    return None


def switch_mode():
    dev = _hidraw('C267')
    if dev is None:
        print('already in native mode' if _hidraw('C266') else 'G923 not found')
        return
    buf = bytes([0x30, 0xf8, 0x09, 0x07, 0x01, 0x01, 0x00, 0x00])
    fd = os.open(dev, os.O_RDWR)
    try:
        fcntl.ioctl(fd, _ioc(3, 'H', 0x0B, len(buf)), buf)  # HIDIOCSOUTPUT
    finally:
        os.close(fd)
    for _ in range(50):  # wait for re-enumeration + calibration
        time.sleep(0.2)
        if _hidraw('C266'):
            break
    time.sleep(4.0)
    print('switched:', _hidraw('C266'))


class Wheel:
    def __init__(self, kp=6.0, kd=0.25, max_force=0.55):
        dev = _hidraw('C266')
        if dev is None:
            raise SystemExit('G923 not in native mode; run "switch" first')
        self.fd = os.open(dev, os.O_RDWR)
        path = os.path.realpath(glob.glob('/dev/input/by-id/usb-Logitech_G923*-event-joystick')[0])
        self.ev = evdev.InputDevice(path)
        ai = self.ev.absinfo(evdev.ecodes.ABS_X)
        self.mid, self.half = (ai.max + ai.min) / 2.0, (ai.max - ai.min) / 2.0
        self.kp, self.kd, self.max_force = kp, kd, max_force
        self.target = 0.0
        self.running = True
        self._send([0xf5, 0, 0, 0, 0, 0, 0])            # autocenter off
        r = int(RANGE_DEG)
        self._send([0xf8, 0x81, r & 0xff, r >> 8, 0, 0, 0])  # set range
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _send(self, cmd):
        os.write(self.fd, bytes([0x00] + cmd))

    def angle(self):
        """Measured angle in degrees, + = left."""
        v = self.ev.absinfo(evdev.ecodes.ABS_X).value
        return -(v - self.mid) / self.half * RANGE_DEG / 2.0

    # Smoothing. The target arrives as steps a few times a second (gateway frames),
    # and a 10 ms finite-difference velocity on the 16-bit axis is noisy, so a raw PD
    # on both jerked the wheel. The reference now chases the target through a
    # first-order lag with a slew limit, velocity is low-passed, and errors inside
    # DEADBAND_DEG produce no force.
    REF_TAU_S = 0.4
    SLEW_DEG_S = 120.0
    VEL_ALPHA = 0.15
    DEADBAND_DEG = 1.5

    # Position control uses the wheel's OWN spring effect with a movable centre, so
    # the closed loop runs in firmware. The host-side PD on constant force (kept below
    # as _loop_pd) was jerky however it was tuned: 8-bit force, USB latency and a
    # noisy finite-difference velocity. Measured on the G923: spring centre 0x80 ->
    # 0 deg, 0xa0 -> -110.7 deg, 0x60 -> +112.6 deg, i.e. ~3.5 deg per count, + = left.
    DEG_PER_COUNT = 3.5
    SPRING_K = 0x03      # 0..7 per side; gentle -- a hand must win easily
    SPRING_CLIP = 0x60   # max spring force, 0..255 (0xa0 felt violent at speed)

    def ref_angle(self):
        """Where the wheel is being held (deg), or None when released."""
        return getattr(self, '_ref', None)

    def _spring(self, centre_angle):
        c = int(round(0x80 - centre_angle / self.DEG_PER_COUNT))
        c = max(1, min(254, c))
        if c != getattr(self, '_last_c', None):
            k = self.SPRING_K
            self._send([0x11, 0x01, c, c, (k << 4) | k, 0x00, self.SPRING_CLIP])
            self._last_c = c

    def _loop(self):
        prev_t = time.monotonic()
        ref = self.angle()
        while self.running:
            now = time.monotonic()
            dt = max(now - prev_t, 1e-3)
            prev_t = now
            if self.target is None:        # released: no spring from us
                if getattr(self, '_last_c', None) is not None:
                    self._send([0x13, 0, 0, 0, 0, 0, 0])
                    self._last_c = None
                ref = self.angle()
                self._ref = None
            else:
                step = (self.target - ref) * min(1.0, dt / self.REF_TAU_S)
                lim = self.SLEW_DEG_S * dt
                ref += max(-lim, min(lim, step))
                self._ref = ref
                self._spring(ref)
            time.sleep(0.02)
        self._send([0x13, 0, 0, 0, 0, 0, 0])            # stop slot 1

    def _loop_pd(self):
        prev, prev_t = self.angle(), time.monotonic()
        ref, vel = prev, 0.0
        while self.running:
            now = time.monotonic()
            dt = max(now - prev_t, 1e-3)
            a = self.angle()
            vel += self.VEL_ALPHA * ((a - prev) / dt - vel)
            prev, prev_t = a, now
            if self.target is None:        # servo released: no constant force
                f, ref = 0.0, a
            else:
                step = (self.target - ref) * min(1.0, dt / self.REF_TAU_S)
                lim = self.SLEW_DEG_S * dt
                ref += max(-lim, min(lim, step))
                err = ref - a
                if abs(err) < self.DEADBAND_DEG:
                    err = 0.0
                f = self.kp * err / 90.0 - self.kd * vel / 90.0   # +f = push left
                f = max(-self.max_force, min(self.max_force, f))
            # classic constant force: 0x80 neutral, higher = left (measured on the G923)
            self._send([0x11, 0x08, int(round(0x80 + f * 127)), 0x80, 0, 0, 0])
            time.sleep(0.01)
        self._send([0x13, 0, 0, 0, 0, 0, 0])            # stop slot 1

    def autocenter(self, on, strength=0x80):
        """Firmware centring spring, for manual driving when the servo is released."""
        if on:
            self._send([0xfe, 0x0d, 0x05, 0x05, strength, 0, 0])
            self._send([0x14, 0, 0, 0, 0, 0, 0])
        else:
            self._send([0xf5, 0, 0, 0, 0, 0, 0])

    def close(self):
        self.running = False
        self.thread.join(timeout=1)
        self._send([0xf3, 0, 0, 0, 0, 0, 0])            # stop all
        os.close(self.fd)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'test'
    if cmd == 'switch':
        switch_mode()
        return
    w = Wheel()
    try:
        if cmd == 'test':
            for tgt in (45.0, -45.0, 0.0):
                w.target = tgt
                time.sleep(2.0)
                print(f'target {tgt:+.0f}  measured {w.angle():+.1f}')
        elif cmd == 'stdin':
            for line in sys.stdin:
                try:
                    w.target = float(line)
                except ValueError:
                    pass
    finally:
        w.close()


if __name__ == '__main__':
    main()
