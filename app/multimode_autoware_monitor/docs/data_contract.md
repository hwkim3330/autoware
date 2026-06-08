# WebSocket Data Contract

The gateway (or the mock server) sends **one JSON object per second** to every
connected client on `ws://<host>:8765/ws`. The Flutter app parses each frame
into `MonitoringData` (see `lib/models/`). Unknown enum strings never crash the
app — they fall back to a safe `unknown` value.

## Top-level shape

| field | type | notes |
|-------|------|-------|
| `timestamp` | string (ISO-8601 UTC) | frame time from the wire |
| `source` | string | `DEMO` / `WIFI` / `USB_ADB` / `VEHICLE` |
| `scenario` | object | current scenario / environment |
| `stateMachine` | object | 6-State driving state machine |
| `localization` | object | current mode + pipeline + fusion |
| `sensors` | object | per-sensor status (5 sensors) |
| `autoware` | object | selected stack + module states |
| `roiiArchitecture` | object | ROii zones / backbone / HPC |
| `metrics` | object | performance + safety |
| `events` | array | recent event log entries |

## Field detail

### scenario
`id`, `name`, `environment`, `drivingArea` (e.g. `URBAN` / `RURAL` / `SUBURBAN`).

### stateMachine
`stateId`, `displayName`, `previousStateId`, `transitionStatus`
(`COMPLETED`/`SWITCHING`/...), `transitionReason`.
`stateId` should be one of the ids in `config/mode_catalog.json` (not hardcoded).

### localization
`mode` ∈ `LIDAR_ONLY|GNSS_ONLY|CAMERA_ONLY|LIDAR_GNSS|LIDAR_CAMERA|GNSS_CAMERA|LIDAR_GNSS_CAMERA|UNAVAILABLE`;
`pipelineType` ∈ `SINGLE|DUAL|TRIPLE|UNAVAILABLE`;
`absoluteSensors[]`, `relativeSensors[]`, `fusionMethod`,
`fusionWeights{lidar,gnss,camera}`, `confidence` (0..1), `latencyMs`.

### sensors
Keys: `lidar`, `gnss`, `camera` (absolute), `imu`, `odometry` (relative).
Each: `status` ∈ `NORMAL|DEGRADED|FAULT|DISABLED|STANDBY`, `used` (bool),
`role` ∈ `ABSOLUTE_LOCALIZATION|RELATIVE_LOCALIZATION|PERCEPTION|SUPPORT|UNUSED`,
`reason` (string).

### autoware
`selectedStack` (see enum list below), `stackReason`,
`modules{sensing,localization,perception,planning,control,map,vehicleInterface}`
each ∈ `RUNNING|LIMITED|STOPPED|ERROR|DISABLED`, `excludedModules[]`.

Stacks: `FULL_STACK, ROI_NDT_URBAN_STACK, MINIMUM_RURAL_STACK,
LIDAR_LOCALIZATION_STACK, GNSS_LOCALIZATION_STACK, CAMERA_LOCALIZATION_STACK,
DUAL_LIDAR_GNSS_STACK, DUAL_LIDAR_CAMERA_STACK, DUAL_GNSS_CAMERA_STACK,
TRIPLE_FUSION_STACK, FALLBACK_STOP_STACK`.

### roiiArchitecture
`hpc`, `backbone{primary10G,secondary10G}`, `zones{frontLeft,frontRight,rear}`,
`sensorMap{frontLeft[],frontRight[],rear[]}`, `dataFlowStatus`.
Status ∈ `NORMAL|DEGRADED|FAULT|RECOVERING|COMPLETED|STANDBY`.

### metrics
`cpuUsagePercent`, `gpuUsagePercent`, `memoryUsagePercent`,
`endToEndLatencyMs`, `localizationLatencyMs`, `modeTransitionTimeMs`,
`architectureReconfigurationTimeMs`, `trajectoryError`,
`resourceSavingPercent`, `safetyState`
(`SAFE|LIMITED_DRIVE|FAIL_SAFE|LOCALIZATION_UNCERTAIN|SAFE_STOP_REQUIRED`).

### events[]
Each: `timestamp` (display string), `level` ∈ `INFO|WARNING|SUCCESS|ERROR`, `message`.

## Example

See `tools/sample_messages/dual_lidar_gnss.json` for a full, valid example
frame. All seven scenario files in that folder conform to this contract.

## Colors (UI mapping)
- green: NORMAL / RUNNING / SAFE / SUCCESS
- amber: DEGRADED / LIMITED / WARNING / LIMITED_DRIVE / LOCALIZATION_UNCERTAIN
- red: FAULT / ERROR / SAFE_STOP_REQUIRED / UNAVAILABLE
- gray: DISABLED / STOPPED / STANDBY
- blue: RECOVERING / SWITCHING / CONNECTING
