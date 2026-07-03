# ROii WebSocket Gateway Commands

`ws://<host>:8765/ws` (adb reverse tcp:8765 tcp:8765 for USB-connected tablet).
Send JSON; most commands are `{"cmd": "..."}` plus extra fields.

| cmd | fields | 설명 |
|---|---|---|
| `teleop` | `v` (m/s), `steer` (rad) | 수동 주행. 0.5s TTL, 주기적으로 재전송 필요 |
| `goto` | `x`, `y` | 목적지 좌표로 자율주행 라우팅 |
| `maxvel` | `kmh` | 최고 속도 제한 |
| `map` | `town` (e.g. `Town04`, `pangyo_crd`) | 맵 전환 (재기동 ~3분) |
| `vehicle` | `model` (`roii` \| `lexus`) | RViz 차량 3D 모델 교체 (rviz 재시작, ~2초) |
| `fault` | `sensor`, `mode` (`drop`\|`stamp_offset`\|`normal`), `duration` | LiDAR 고장 주입 (front_g32/rear_g32/left_pandar/right_pandar) |
| `gnss_fault` | `mode` | GNSS 고장 주입 |
| `trigger_emergency` | — | 강제 비상정지 (STOP 모드) |
| `clear` | — | 라우트 초기화 |
| `stop` | — | STOP 모드 전환 |
| `drive` | — | 자율주행 모드 전환 |
| `respawn` | — | 차량 재위치 + NDT/EKF 강제 재수렴 |
| `fail_lidar` | — | LiDAR 전체 고장 시뮬레이션 (멀티모드 폴백 트리거) |
| `heal` | — | 주입된 고장 전부 해제 |

## 예시 (Python)
```python
import asyncio, json, websockets
async def send(cmd):
    async with websockets.connect("ws://localhost:8765/ws") as ws:
        await ws.send(json.dumps(cmd))
asyncio.run(send({"cmd": "vehicle", "model": "roii"}))
asyncio.run(send({"cmd": "fault", "sensor": "right_pandar", "mode": "drop", "duration": 20.0}))
```

## 참고
- `vehicle` 모델 기본값은 `roii` (실제 ROii 셔틀 메시). `lexus`로 전환하면
  `container_patches/lexus_stock.dae` 백업본으로 되돌아감.
- `fault`의 `sensor` 이름은 4개 고정: `front_g32`, `rear_g32`, `left_pandar`, `right_pandar`.
