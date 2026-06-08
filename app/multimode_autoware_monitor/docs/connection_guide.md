# Connection Guide

The app supports four data sources, selectable in **Settings**. It always
starts in **DEMO** and never freezes — any connection failure falls back to
DEMO automatically, and stale data (no frame for 4 s) is flagged.

## 1. DEMO (default)
In-app mock data. No server, no network. Cycles the 7 reference scenarios.
Good for showcasing the UI on the tablet with nothing else running.

## 2. Wi-Fi Mode (primary experiment path)
Tablet and PC on the **same Wi-Fi**.

1. On the PC, start the server:
   ```bash
   cd tools
   python3 -m venv .venv && source .venv/bin/activate
   pip install websockets
   python mock_ws_server.py
   ```
   It prints the Wi-Fi URL, e.g. `ws://192.168.0.10:8765/ws`.
2. Find the PC IP if needed: `hostname -I` (Linux) / `ipconfig` (Windows).
3. In the app: Settings → Data Source = **WIFI** → URL =
   `ws://<PC-IP>:8765/ws` → **Connect**.

Firewall: allow inbound TCP 8765 on the PC.

## 3. USB ADB Mode (backup, no shared Wi-Fi needed)
Works over the USB cable even on different networks / behind firewalls.

1. Connect the tablet by USB, enable USB debugging.
2. On the PC:
   ```bash
   adb devices
   adb reverse tcp:8765 tcp:8765
   ```
   `adb reverse` makes the tablet's `127.0.0.1:8765` tunnel to the PC's 8765.
3. Start `mock_ws_server.py` on the PC (listens on 0.0.0.0:8765).
4. In the app: Settings → Data Source = **USB_ADB** (URL auto-set to
   `ws://127.0.0.1:8765/ws`) → **Connect**.

## 4. CUSTOM_NETWORK
Same as Wi-Fi but you type any URL (remote server, VPN, etc.).

## Troubleshooting
- **Stuck on CONNECTING / falls back to DEMO**: server not reachable. Check IP,
  port 8765, firewall, and that the server is running.
- **STALE DATA badge**: connected but no frame for >4 s. Check the server is
  still publishing.
- **USB ADB not working**: re-run `adb reverse tcp:8765 tcp:8765` (it resets on
  replug), confirm `adb devices` lists the tablet.
- **Wrong path**: URL path must be `/ws`.
