# ROii 장애감지·재구성 시스템 — 구조 정리 (2026-07-07)

과제 핵심 결과물("센서/통신/모듈 상태 모니터링 + 장애 유형 분류 + 주행 모드 재구성")을 구현한
6개 노드가 서로 얽혀있어서 헷갈리기 쉬움. 이 문서 하나로 "뭐가 뭔지" 정리.

## 전체 그림 (`./run.sh roii low|mid|high [Town]` 실행 시)

```
CARLA 센서 (sensor_mapping_roii_lidar_{low,mid,high}.yaml로 설정됨)
    │  /sensing/lidar/{front_g32,rear_g32,left_pandar,right_pandar}/pointcloud_raw
    ▼
roii_lidar_fault_injector.py   ← /roii/fault_injector/command (앱 FAULT 버튼)
    │  (정상 통과 또는 drop/delay/downsample/stamp_zero/stamp_offset/freeze 주입)
    │  /sensing/lidar/{s}/pointcloud_before_sync
    ├──────────────────────────────────┐
    ▼                                  ▼
pointcloud_preprocessor_roii   roii_lidar_health_monitor.py
  .launch.py (concat)            (per-sensor Hz/timeout/TF/stamp 체크)
    │                                  │  /roii/lidar_health, /diagnostics
    ▼                                  │
concatenated/pointcloud                │
    │                                  │
    ▼                                  │
roii_fault_detector.py  ◄──────────────┘ (별도, publisher-count 기반)
    │  /roii/fault_report (전체 상태, 1Hz)
    ▼
roii_watchdog.py  ◄── /roii/fault_injector/status, /roii/gnss_fault/status
    │  (자체 _detect/_evaluate: 모드 전환 NORMAL→DEGRADED_3/2/1→GNSS_FALLBACK→MRM)
    │  /roii/reconfig_status
    ▼
ros_ws_gateway.py → 태블릿 앱
```

GNSS 쪽은 별도 평행선:
```
/sensing/gnss/pose_with_covariance (실제 GNSS)
    ▼
roii_gnss_fault_injector.py  ← /roii/gnss_fault/command (앱)
    │  /roii/gnss/pose_with_covariance (LiDAR와의 갭 표시용)
    │  /roii/gnss_fault/status
    ▼
ros_ws_gateway.py → 태블릿 앱
```

## 노드별 역할 (겹치는 것처럼 보이지만 다름)

| 파일 | 구독 방식 | 역할 | 출력 |
|---|---|---|---|
| `roii_lidar_fault_injector.py` | 메시지 구독 (4라이다 원본) | 장애 **주입** (raw→before_sync 사이) | `pointcloud_before_sync` ×4, `/roii/fault_injector/status` |
| `roii_gnss_fault_injector.py` | 메시지 구독 (GNSS) | 장애 **주입** (GNSS) | `/roii/gnss/pose_with_covariance`, `/roii/gnss_fault/status` |
| `roii_lidar_health_monitor.py` | 메시지 구독 (before_sync ×4) | 센서별 상세 헬스(Hz/timeout/TF/stamp/point수) | `/roii/lidar_health`, `/diagnostics` |
| `roii_fault_detector.py` | **구독 없음**, publisher-count만 (DDS 크래시 회피) | 전체 요약(라이다 통합 rate + 모듈) | `/roii/fault_report` |
| `roii_watchdog.py` | 메시지 구독 (injector status, GNSS fault, perception, odom) | **실제 동작하는** 모드 전환 로직 + 기존 watchdog(gateway/perception 자동복구) | `/roii/watchdog`, `/roii/reconfig_status` |
| ~~`roii_reconfig_manager.py`~~ | (삭제됨, 2026-07-07) | — 아무 것도 안 함, 아래 참고 | — |

`roii_fault_detector.py`와 `roii_watchdog.py`가 비슷한 "모드 판단" 코드를 각자 갖고 있는 게
중복처럼 보이는데, 실제로 게이트웨이(`ros_ws_gateway.py`)가 읽는 건 `/roii/reconfig_status`
(watchdog 산출)뿐이고 `/roii/fault_report`(fault_detector 산출)는 별도의 "원시 상태 텔레메트리"
역할 — watchdog은 injector-status를 실제로 구독해서 반영하지만 fault_detector는 구독 없이
publisher-count만 보기 때문에 개별 라이다 장애를 구분 못 하고 통합 rate만 봄. 의도된 역할 분리임.

## 2026-07-07에 고친 것

1. **`roii_reconfig_manager.py` 통째로 죽어있었음** — `_detect_faults()`→`_evaluate()` 체인이
   타이머/구독 어디에도 안 걸려있어서 `/roii/driving_mode`를 평생 발행 안 함(어차피 아무도 구독도
   안 함). `roii_watchdog.py`의 docstring "재구성 관리자 (통합)"이 가리키는 게 바로 이 파일이
   하려던 일의 완성 버전 — 그래서 삭제하고 `scripts/run_localization_demo.sh`의 배포 라인도 제거.
2. **`roii_fault_detector.py`의 죽은 분기 제거** — `_injector_status`가 항상 빈 딕셔너리인데
   그걸 읽는 if/else가 남아있었음 (자체 주석에 "reconfig_manager에서 직접 읽으므로 여기서
   제거"라고 이미 써있었는데 죽은 코드만 안 지워짐). 안 쓰는 RateEstimator/콜백 스텁/QoS/import,
   구현 안 된 fault 타입(TIMESTAMP_FAULT 등) docstring 과장도 정리.

## 헷갈리기 쉬운 함정 — sensor_mapping 파일이 두 계열임

`config/` 밑에 `sensor_mapping_roii_*.yaml`이 여러 개 있는데 **서로 다른 실행 모드용**임,
섞으면 안 됨:

- `sensor_mapping_roii_lidar_{low,mid,high}.yaml` — `./run.sh roii low|mid|high`용.
  센서 이름 `front_g32/rear_g32/left_pandar/right_pandar`, topic_suffix `/pointcloud_raw`.
  **이 문서에서 설명한 장애감지 파이프라인 전체가 이 계열과 짝을 이룸.**
- `sensor_mapping_roii_4lidar.yaml` — `run_localization_demo.sh`의 `LIDARS=4` 모드용
  (별도 경로, 장애감지 서브시스템 없음). 센서 이름 `front/rear/side_left/side_right`,
  topic_suffix `/pointcloud_before_sync` (injector 없이 바로 발행). **이름 체계가 완전히
  다름** — 이번에 이 파일 보고 "토픽명 안 맞는 큰 버그다" 오판했다가 다른 모드용 파일이란 걸
  나중에 확인함. 다음에 또 이 폴더 뒤질 때 이 구분 기억할 것.

## 참고

- `docs/gateway_control_path.md` — 게이트웨이 제어경로(수동조작) 관련, 이 문서와는 별개 주제
- `docs/roii_lidar_carla_autoware.md` — ROii 4-LiDAR 센서 스펙/커버리지 상세
