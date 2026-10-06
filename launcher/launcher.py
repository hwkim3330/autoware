#!/usr/bin/env python3
"""ROii Drive launcher: one page to start a scenario, the wheel, and the dashboard.

    python3 launcher/launcher.py            # http://127.0.0.1:8800

Serves the launcher page, the dashboard (webapp/, so models/*.glb load over
http instead of being blocked under file://) and a small JSON API:

    GET  /api/status              running scenario, gateway, load, GPU, wheel
    POST /api/start  {"id": ...}  start a scenario (stops whatever runs first)
    POST /api/stop                stop every simulator and the Autoware stack
    POST /api/wheel  {"on": bool} start/stop the G923 bridge
    GET  /api/log?name=...        last lines of a scenario/wheel log

Scenarios are the existing bring-up scripts; this only starts, stops and
watches them. Only stdlib.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.expanduser("~/.cache/roii_launcher")
os.makedirs(LOGDIR, exist_ok=True)
PORT = int(os.environ.get("LAUNCHER_PORT", "8800"))

SCENARIOS = [
    {"id": "shinjuku", "title": "신주쿠", "sub": "AWSIM · 도심 자율주행",
     "cmd": ["bash", f"{REPO}/scripts/run_awsim.sh"], "boot_s": 330},
    {"id": "pangyo", "title": "판교", "sub": "AWSIM · KETI 주변 실측 지도",
     "cmd": ["bash", f"{REPO}/scripts/run_pangyo_awsim.sh"], "boot_s": 360},
    {"id": "carla_roii", "title": "ROii 4-LiDAR", "sub": "CARLA Town04 · 센서 재구성",
     "cmd": ["bash", f"{REPO}/run.sh", "roii", "low", "Town04"], "boot_s": 420},
    {"id": "race", "title": "레이싱 트랙", "sub": "준비 중 · AI와 대결", "cmd": None, "boot_s": 0},
]
BY_ID = {s["id"]: s for s in SCENARIOS}

STATE = {"scenario": None, "started": 0.0, "proc": None, "wheel": None}
LOCK = threading.Lock()


def _spawn(cmd, log_name, env=None):
    log = open(os.path.join(LOGDIR, log_name + ".log"), "wb")
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, cwd=REPO,
                            start_new_session=True, env=env or os.environ.copy())


def _kill_group(p):
    if p and p.poll() is None:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def stop_all():
    with LOCK:
        _kill_group(STATE["proc"])
        STATE.update(scenario=None, proc=None, started=0.0)
    subprocess.run(["bash", f"{REPO}/scripts/killall_sims.sh"], cwd=REPO,
                   stdout=open(os.path.join(LOGDIR, "stop.log"), "wb"), stderr=subprocess.STDOUT)


def start(sid):
    sc = BY_ID.get(sid)
    if not sc or not sc["cmd"]:
        return False, "이 시나리오는 아직 준비 중입니다"
    set_wheel(False)
    stop_all()
    with LOCK:
        STATE.update(scenario=sid, started=time.time(), proc=_spawn(sc["cmd"], sid))
    return True, f"{sc['title']} 시작"


def set_wheel(on):
    with LOCK:
        p = STATE["wheel"]
        if on and (p is None or p.poll() is not None):
            env = os.environ.copy()
            env["PYTHONPATH"] = os.path.expanduser("~/.local/lib/python3.12/site-packages")
            STATE["wheel"] = _spawn([sys.executable, "-u", f"{REPO}/ros/g923_awsim_demo.py"], "wheel", env)
        elif not on and p is not None:
            _kill_group(p)            # the bridge stops the wheel's forces on SIGTERM
            STATE["wheel"] = None


def _gateway_up():
    try:
        with socket.create_connection(("127.0.0.1", 8765), timeout=0.3):
            return True
    except OSError:
        return False


def status():
    with LOCK:
        sid, started, p, w = STATE["scenario"], STATE["started"], STATE["proc"], STATE["wheel"]
    sc = BY_ID.get(sid) if sid else None
    phase = "idle"
    if sc:
        if p and p.poll() is None:
            phase = "booting"
        elif _gateway_up():
            phase = "ready"
        else:
            phase = "failed" if p and p.returncode not in (0, None) else "booting"
    gpu = None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=2).stdout
        u, t, g = [int(x) for x in out.split(",")[:3]]
        gpu = {"usedMB": u, "totalMB": t, "util": g}
    except Exception:
        pass
    return {
        "scenario": sid, "title": sc["title"] if sc else None, "phase": phase,
        "elapsed": round(time.time() - started) if started else 0, "bootS": sc["boot_s"] if sc else 0,
        "gateway": _gateway_up(), "wheel": bool(w and w.poll() is None),
        "load": os.getloadavg()[0], "cpus": os.cpu_count(), "gpu": gpu,
        "scenarios": [{k: s[k] for k in ("id", "title", "sub")} | {"ready": bool(s["cmd"])} for s in SCENARIOS],
    }


def tail(name, n=40):
    path = os.path.join(LOGDIR, os.path.basename(name) + ".log")
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 20000))
            lines = f.read().decode("utf-8", "replace").replace("[sudo] password for kim: ", "").splitlines()
        return "\n".join(lines[-n:])
    except OSError:
        return ""


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=REPO, **kw)

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            self.path = "/launcher/index.html"
        elif u.path in ("/dashboard", "/dashboard/"):
            self.path = "/webapp/tesla_dashboard.html"
        elif u.path == "/api/status":
            return self._json(status())
        elif u.path == "/api/log":
            return self._json({"text": tail(parse_qs(u.query).get("name", ["shinjuku"])[0])})
        elif not (u.path.startswith("/launcher/") or u.path.startswith("/webapp/")):
            return self.send_error(404)
        return super().do_GET()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        p = urlparse(self.path).path
        if p == "/api/start":
            ok, msg = start(body.get("id"))
            return self._json({"ok": ok, "msg": msg})
        if p == "/api/stop":
            set_wheel(False)
            threading.Thread(target=stop_all, daemon=True).start()
            return self._json({"ok": True, "msg": "모두 종료하는 중"})
        if p == "/api/wheel":
            set_wheel(bool(body.get("on")))
            return self._json({"ok": True})
        return self.send_error(404)


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"ROii launcher: http://127.0.0.1:{PORT}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        set_wheel(False)


if __name__ == "__main__":
    main()
