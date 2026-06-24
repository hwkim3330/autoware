# SSU HMI Network Setup

Connecting the Android HMI app to the read-only `niro_hmi_gateway`.

## Endpoint

The gateway serves a WebSocket at:

```
ws://<PC-IP>:<port>/ws
```

| Profile | Default port |
|---------|--------------|
| `ssu_niro` (real vehicle) | **8765** |
| `carla_niro` (simulation) | **8766** |
| `generic_autoware` | see `config/hmi/generic_autoware.yaml` |

The host/port/path come from the `network:` block of the profile YAML
(`host: 0.0.0.0`, `path: /ws`).

## Finding the PC IP

```bash
hostname -I | awk '{print $1}'      # first IPv4
ip -4 addr show                     # all interfaces
```

Use the address on the interface shared with the Android device (Wi-Fi AP,
Ethernet subnet, or the USB/ADB link).

## 1. Wi-Fi (same LAN / AP)

Point the Android app at:

```
ws://<PC-IP>:8765/ws        # ssu_niro
ws://<PC-IP>:8766/ws        # carla_niro
```

Both the PC and the tablet must be on the same network and able to reach each
other (no client isolation on the AP).

## 2. Ethernet (direct or switch)

Same URL form as Wi-Fi, using the PC's Ethernet IP. For a direct PC↔tablet
cable, assign static IPs in the same subnet (e.g. PC `192.168.50.1`,
tablet `192.168.50.2`) and connect to `ws://192.168.50.1:8765/ws`.

## 3. USB (ADB reverse)

With the tablet on USB and USB debugging enabled, forward the device's local
port to the PC so the app can use `localhost`:

```bash
adb reverse tcp:8765 tcp:8765      # ssu_niro
adb reverse tcp:8766 tcp:8766      # carla_niro
```

The Android app then connects to `ws://127.0.0.1:8765/ws`. `adb reverse` makes
the phone's `localhost:<port>` tunnel to the PC's `localhost:<port>`, so no IP
discovery is needed. Re-run after replugging the cable.

## Firewall

For Wi-Fi/Ethernet, ensure the gateway port is allowed inbound on the PC. USB
(`adb reverse`) tunnels over the ADB connection and is not affected by the
firewall. Example (ufw):

```bash
sudo ufw allow 8765/tcp     # ssu_niro
sudo ufw allow 8766/tcp     # carla_niro
```

## Quick check

```bash
ss -ltn | grep -E ':(8765|8766) '   # gateway listening?
```

The launcher (`scripts/run_niro_hmi_gateway.sh`) already warns if the port is
already in use.
