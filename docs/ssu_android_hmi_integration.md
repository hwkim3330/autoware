# SSU Android HMI Integration

Read-only telemetry bridge from the niro ROS2 stack (CARLA simulation **or** the
SSU real vehicle) to an Android HMI app over WebSocket/JSON.

## System architecture

```
  ROS2 (niro stack)                Gateway PC                         Android
  ┌────────────────┐      ┌──────────────────────────┐        ┌───────────────┐
  │ /multimode/*    │      │ niro_hmi_gateway.py       │        │  Flutter HMI  │
  │ /localization/* │ ───► │  (READ-ONLY)              │        │  (display     │
  │ trajectory      │ subs │  ├─ hmi_adapters/*        │  WS    │   only)       │
  │ operation/route │      │  │  parse → HmiState      │ ─JSON► │               │
  │ mrm, vehicle/*  │      │  └─ broadcast @10Hz       │        │               │
  └────────────────┘      └──────────────────────────┘        └───────────────┘
                                 ws://<PC-IP>:<port>/ws
                            Wi-Fi / Ethernet / USB (adb reverse)
```

- **Subscribe-only.** The gateway creates ROS *subscriptions* only — never a
  publisher, service client, or action client. Inbound WebSocket messages from
  Android are logged and ignored.
- A profile selects which topics to read and which port to serve.

## Components (this branch)

| File | Role |
|------|------|
| `ros/niro_hmi_gateway.py` | Main gateway: loads a profile, builds the adapter, spins ROS on a background thread, broadcasts `HmiState` JSON at 10 Hz over WebSocket. |
| `ros/hmi_state.py` | ROS-free state container + JSON serializer (schema `1.0`). |
| `ros/hmi_adapters/base_adapter.py` | Shared subscribe + parse helpers; skips empty topics with a warning. |
| `ros/hmi_adapters/carla_niro_adapter.py` | CARLA-sim profile adapter. |
| `ros/hmi_adapters/ssu_niro_adapter.py` | SSU real-vehicle profile adapter. |
| `ros/hmi_adapters/generic_autoware_adapter.py` | Neutral Autoware profile adapter. |
| `config/hmi/carla_niro.yaml` | CARLA-sim profile, port **8766**. |
| `config/hmi/ssu_niro.yaml` | SSU real-vehicle profile, port **8765**. |
| `config/hmi/generic_autoware.yaml` | Generic Autoware profile. |
| `scripts/run_niro_hmi_gateway.sh` | Launcher with dependency / port preflight checks. |

## Running

```bash
# SSU real vehicle (port 8765)
./scripts/run_niro_hmi_gateway.sh ssu_niro

# CARLA simulation (port 8766) — can run alongside ssu_niro
./scripts/run_niro_hmi_gateway.sh carla_niro
```

The CARLA and real-vehicle gateways use **different default ports** (8766 vs
8765) and share no state, so both can run side by side. The gateway also does
not touch `ros/ros_ws_gateway.py` (the CARLA control path).

## Simulation vs real-vehicle

| | `carla_niro` (sim) | `ssu_niro` (real) |
|---|---|---|
| `source` field | `simulation` | `real_vehicle` |
| Port | 8766 | 8765 |
| Localization topics | `/niro/multimode/*`, `/localization/niro/fused_pose` | `/multimode/*`, `/localization/multimode/pose_with_covariance` |
| Autoware topics | odometry/trajectory/operation/route populated | empty in the profile (skipped) until confirmed on the real vehicle |

The adapter abstraction means the Android client sees the **same JSON schema**
regardless of source; only the `source`/`profile` fields and which sub-objects
are populated differ. Topics left empty in a profile are warned + skipped (not
guessed).

## WebSocket JSON schema (what the gateway emits)

Broadcast at ~10 Hz. Shape produced by `HmiState.to_json()`:

```json
{
  "type": "status",
  "schemaVersion": "1.0",
  "sequence": 1234,
  "timestamp": "2026-06-24T01:23:45.678Z",
  "profile": "ssu_niro",
  "source": "real_vehicle",
  "capabilities": {
    "readOnly": true,
    "setRoute": false, "engage": false, "stop": false,
    "mrm": false, "teleop": false, "faultInjection": false
  },
  "connection": { "rosConnected": true, "dataStale": false, "lastUpdateMs": null },
  "vehicle": { "speedKmh": 12.3, "steeringDeg": -1.5 },
  "localization": {
    "mode": "LIDAR", "valid": true, "converged": true,
    "lidarWeight": 1.0, "gnssWeight": 0.0, "cameraWeight": null,
    "lidarFresh": true, "gnssFresh": false,
    "lidarPoseAgeSec": 0.02, "gnssPoseAgeSec": null,
    "timestampDiffSec": null, "pipelineGapM": null
  },
  "sensors": { "lidar": "NORMAL", "gnss": "UNAVAILABLE", "imu": "NORMAL", "camera": "UNAVAILABLE" },
  "autoware": { "operationMode": "UNKNOWN", "routeState": "UNKNOWN", "mrmState": "UNKNOWN" },
  "events": []
}
```

- `capabilities.readOnly` is **always `true`** in this phase; every command
  capability is `false`, regardless of `command.enabled` in the YAML.
- Numeric fields are `null` when no source is configured/available (never `0`).
- `sensors.*` enum: `NORMAL` / `FAULT` / `UNAVAILABLE`.

## Extending to commands later

This phase is read-only by contract. To add commands later:
1. Set `command.enabled: true` in the profile and define a command allow-list.
2. Replace the gateway's ignore-inbound `handler()` with a validated command
   dispatcher and add the corresponding ROS publishers/clients in a dedicated
   command module (keep them out of the read-only adapters).
3. Flip the relevant `capabilities.*` flags in `build_capabilities()` so the
   Android client can enable the matching controls — the schema already carries
   the capability map for exactly this purpose.
