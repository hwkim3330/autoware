# 게이트웨이 수동조작(teleop) 제어 경로 — 공식 대비 실제

`ros_ws_gateway.py`는 Autoware 공식 컴포넌트가 아니다. 태블릿 앱의 단순 `{cmd:teleop,v,steer}`
WebSocket 메시지를 Autoware의 실제 ROS2 토픽/서비스로 번역해주는 자체 제작 브릿지다. Autoware
자체엔 "앱/조이스틱으로 조작하기"에 대한 공식 표준 클라이언트가 없고, 있는 건 물리적
페달/스티어링 휠 하드웨어를 위해 설계된 오래된 TIER IV 배선(`external_cmd_selector` →
`external_cmd_converter` → `vehicle_cmd_gate`)뿐이다. 이 문서는 그 공식 배선이 실제로 뭘
요구하는지, 이 프로젝트가 지금까지 뭘 했는지, 왜 여러 번 바이패스로 흘렀는지를 실제 소스
코드 기준으로 정리한다.

## 공식 배선 (양쪽 백엔드 공통, autoware_universe 소스 확인)

```
앱 --ws--> gateway --publish--> gate의 EXTERNAL 입력 토픽 (/external/selected/*)
                                      │
                          vehicle_cmd_gate (arbitrates AUTO vs EXTERNAL vs EMERGENCY)
                                      │  output/control_cmd, output/gear_cmd
                                      ▼
                          /control/command/{control_cmd,gear_cmd}   (게이트 전용 출력)
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼ (CARLA)                            ▼ (AWSIM)
      raw_vehicle_cmd_converter                 vehicle interface (직접 구독)
      (velocity/accel -> throttle/brake)          AWSIM AccelVehicle.cs
                    │
                    ▼
      /control/command/actuation_cmd (게이트 전용 아님, 컨버터 전용 출력)
                    │
                    ▼
              carla_ros.py control_callback -> CARLA VehicleControl
```

게이트가 실제로 우리 EXTERNAL 명령을 통과시키려면 **세 가지가 동시에** 맞아야 한다
(`vehicle_cmd_gate.cpp` 직접 확인, 2026-07-07):

1. `/control/gate_mode_cmd` = `EXTERNAL(1)` — 명령 소스를 auto_commands_ 대신
   remote_commands_로 선택.
2. `/autoware/engage` (또는 `/api/autoware/set/engage`) = `true` — **이게 계속 빠져있던
   조건.** `publishControlCommands()`는 `gate_mode`/명령소스와 무관하게
   `if (!is_engaged_) { filtered_control.longitudinal = createLongitudinalStopControlCmd(); }`
   를 무조건 실행한다. EXTERNAL 모드만 켜는 걸로는 절대 안 움직인다.
3. `/external/selected/{control_cmd,gear_cmd}`에 실제 명령 발행 — 게이트의
   `input/external/{control_cmd,gear_cmd}` remap 대상.

## 지금까지의 히스토리 (git log로 재구성)

| 시점 | 커밋 | 뭘 했는지 | 왜 |
|---|---|---|---|
| 06-09 | `efbabe6` | `/external/selected/control_cmd` 시도 → 되돌림, `/control/command/control_cmd`(게이트 출력) 직접발행으로 전환 | "external/selected path didn't drive the vehicle" — **원인 진단 안 하고 바이패스로 우회** |
| 06-10 | `f57ee90` | gear_cmd도 `/external/selected/gear_cmd` → `/control/command/gear_cmd`로 전환 | CARLA 인터페이스(`carla_ros.py`)가 게이트 출력 gear_cmd를 직접 구독하길 원해서 |
| ~06-xx | `e78660a` | CARLA 후진 고장: "cmd_gate가 미engage 상태에서 PARK(22) 스팸 → REVERSE(20) 덮어씀" 진단, `/roii/manual_reverse` 전용 래치 + `actuation_cmd` 직접발행(`pub_act`)으로 우회 | **이것도 정확히 같은 is_engaged_ 문제였는데, 근본원인 대신 또 바이패스 추가** |
| 06-30 | `c8ef65d` | AWSIM용 `ControlModeCommand.AUTONOMOUS` 서비스 호출 추가 (실제로는 게이트가 아닌 다른 서비스 — `is_engaged_`엔 영향 없음), 기존 바이패스는 그대로 유지 | AWSIM 후진 부호 버그 고치면서 손댐, 근본원인은 다시 안 봄 |
| 07-07 | `36eba11`→`ceec6ff` | `vehicle_cmd_gate.cpp` 실제 소스 확인, `is_engaged_` 요구사항 발견, `/autoware/engage` 발행 추가 + gate_mode AUTO 복귀 로직 추가 | **드디어 근본원인 수정** (사용자가 "공식좀 잘봐" 라고 지적해서 다시 팜) |

패턴이 명확하다: **세 번(efbabe6, f57ee90, e78660a) 모두 같은 `is_engaged_` 문제를 다른 각도로
만났고, 매번 소스를 안 읽고 바이패스로 우회했다.** 지금 07-07 수정이 이 프로젝트 역사상 처음으로
근본원인(`is_engaged_`)을 실제로 고친 시도다.

## 현재 상태 — 백엔드별

### AWSIM (완전히 정리됨, 07-07 수정 이후)
- `pub_ctrl`/`pub_gear` → `/external/selected/{control_cmd,gear_cmd}` (게이트가 arbitrate)
- `/autoware/engage` = true, `/external/selected/heartbeat` 발행
- 바이패스 없음 — AWSIM은 `_carla_direct` 같은 액터-직접 경로가 없어서 애초에 우회할 방법이
  없었고, 그래서 이 문제가 AWSIM에서는 "차가 안 움직인다"로 눈에 보였다.
- 아직 라이브로 검증 못 함 (컴자원 문제로 이번 세션엔 실행 안 함).

### CARLA (바이패스 3개가 아직 남아있음 — 의도적으로 안 건드림)
같은 `ros_ws_gateway.py`를 CARLA도 공유하므로 위 게이트 수정은 CARLA에도 그대로 적용된다.
하지만 CARLA는 게이트 출력을 우회하는 경로가 **3개** 겹쳐 있다:

1. **ROS2 정식 경로**: `/external/selected/*` → 게이트 → `raw_vehicle_cmd_converter` →
   `/control/command/actuation_cmd` → `carla_ros.py`의 `control_callback`.
2. **`pub_act` 직접발행** (`e78660a`): 게이트가 미engage 상태서 PARK 스팸하던 걸 피하려고
   `/control/command/actuation_cmd`에 직접 씀 — **`raw_vehicle_cmd_converter`의 전용 출력
   토픽과 경합**. `pub_act`를 만든 이유(is_engaged_ 미설정)는 이제 고쳐졌으므로 이론상 더는
   필요 없어 보이지만, **실제로 검증한 적이 없다** (아래 참고).
3. **`_carla_direct`/`_carla_loop` 액터 직접제어**: ROS2 스택 전체를 건너뛰고 CARLA API로
   직접 `ego.apply_control()` 호출 (별도 스레드, 30Hz). 이건 `is_engaged_` 문제와 무관한,
   **응답성을 위한 의도적 설계** (ROS2 홉 여러 개 도는 것보다 지연이 짧음) — 버그가 아니라
   선택. 계속 유지.

`pub_act`를 지금 지우지 않은 이유: `e78660a` 시점에 `_carla_loop`가 이미 존재했는데도 별도로
`pub_act`+전용 래치를 또 추가해야 후진이 "verified"됐다는 커밋 기록이 있음 — 즉 액터-직접
경로 하나만으로는 그 당시 충분하지 않았다는 뜻일 수 있다 (is_engaged_ 문제 때문이었을 수도,
다른 이유였을 수도 — 확인 안 됨). CARLA는 이 프로젝트의 **가장 성숙하고 기본으로 쓰는
백엔드**라서, 라이브로 재검증 없이 이 셋 중 하나를 걷어내는 건 위험이 이득보다 큼.

## 다음에 컴자원 있을 때 검증할 것 (순서대로)

1. CARLA 전진: 지금도 되는지 (회귀 확인, `_carla_direct` 있든 없든 항상 됐다고 기록됨).
2. CARLA 후진: `pub_act` 없이 `_carla_loop` 단독으로도 되는지 — 되면 `pub_act`/전용
   actuation 바이패스는 삭제 대상 (경합만 없애는 순수 이득).
3. AWSIM 수동조작: 이번 07-07 수정(`/autoware/engage` + `/external/selected/*`)이 실제로
   차를 움직이는지 — 안 되면 `is_engaged_` 외에 다른 조건이 더 있다는 뜻이므로 다시
   `vehicle_cmd_gate.cpp`를 봐야 함 (`enable_cmd_limit_filter_`/`adapi_pause_`/
   `moderate_stop_interface_` 순서로 의심).

## 교훈

"차가 움직이면 그게 맞는 방법"이라고 넘기지 말 것 — 세 번이나 같은 버그를 다른 이름의
바이패스로 우회했다. 다음에 뭔가 게이트/컨버터/인터페이스 관련해서 "안 움직여서 직접 썼다"는
코드를 보면, 이 문서의 3조건(gate_mode/is_engaged_/명령발행)부터 확인하고, 안 되면
`autowarefoundation/autoware_universe`의 해당 노드 소스를 직접 받아서 읽을 것
(`gh api repos/autowarefoundation/autoware_universe/contents/<path>`).
