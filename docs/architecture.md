# 전체 아키텍처: Autoware 중심 + 교체 가능한 백엔드

이 저장소는 **Autoware(ROS 2 Humble)를 중간 계층(공통 자율주행 스택)**으로 두고,
그 아래에 서로 다른 **시뮬레이션/데이터 백엔드**를 갈아끼울 수 있게 구성되어 있다.
Autoware 코어(측위·경로·행동/모션 계획·MPC 제어)는 백엔드가 뭐든 동일하게 동작하고,
백엔드는 센서 데이터(LiDAR/카메라/GNSS/IMU)와 차량 제어 인터페이스만 제공하면 된다.

```
                    ┌─────────────────────────────────────┐
                    │        Autoware (ROS 2 Humble)        │
                    │  NDT 측위 → lanelet2 라우팅 → 행동/   │
                    │  모션 계획 → MPC 제어                 │
                    └───────────────┬───────────────────────┘
                                     │ sensor topics / vehicle cmd
        ┌──────────────┬────────────┼────────────┬──────────────────┐
        │              │            │            │                  │
   [CARLA 0.9.16]  [AWSIM]     [실제 지도       [rosbag 리플레이   [실차/Niro]
   시뮬레이터       (Shinjuku)   planning_sim]   (숭실대 등)]      (Ouster OS2-128)
   기본/가장 성숙    실험적,      CARLA 없이       녹화된 실주행     듀얼 측위
                     측위 미완    라이브 지도       데이터 재생       (LiDAR+GNSS)
        │              │            │            │                  │
        └──────────────┴────────────┴────────────┴──────────────────┘
                                     │
                          ros_ws_gateway.py (WebSocket :8765)
                                     │
                          ┌──────────┴──────────┐
                          │   태블릿 앱 (Flutter) │
                          │  모니터링 + 수동조작   │
                          └───────────────────────┘
```

**MORAI는 사용하지 않는다.** 초기 계획엔 있었으나(`docs/awsim_setup.md` 참고),
AWSIM으로 대체하기로 결정되어 실제 구현/스크립트는 존재하지 않는다.

## 백엔드별 상태 요약

| 백엔드 | 성숙도 | 지도 | 자율주행 폐루프 | 진입점 |
|---|---|---|---|---|
| **CARLA** | ★★★ 가장 성숙, 기본값 | Town01/02/04/06/07 (자율주행 검증됨), Town03/05/10HD 실패 | ✅ 동작 (최대 ~28km/h) | `./run.sh [Town04]` |
| **CARLA + ROii 4-LiDAR** | ★★☆ 센싱은 검증, 완전자율은 상위 planner 부하로 미확정 | 위와 동일 | 센싱/측위만 검증 (10Hz concat, NDT 수렴) | `./run.sh roii low\|mid\|high [Town]` |
| **AWSIM** | ★☆☆ 실험 단계 | Shinjuku(신주쿠) 1개 | ❌ 센싱→NDT 파이프라인 미완성 (IMU 타임스탬프 문제로 NDT 입력 없음) | `./scripts/run_awsim.sh` |
| **실제 지도 (planning_sim)** | ★★☆ 측위는 동작, 라우팅 불완전 | pangyo(NGII), soongsil, sample-map-planning | ⚠️ 측위 OK, 자율 라우팅 그래프 연결성 미완 | `./run.sh real [경로]` |
| **rosbag 리플레이** | ★★★ 안정적 (녹화된 데이터 재생) | 녹화 시점 지도 그대로 | N/A (재생만, 실시간 계획 없음) | `./run.sh replay [bag] [town]`, `./run.sh soongsil` |
| **실차 (Niro)** | ★★☆ 듀얼측위 구조 구현, 실차 테스트 불가(HW 없음) | Town 계열 (센서만 실차 스펙) | 듀얼측위(LiDAR+GNSS) 페일오버 구조만 검증 | `./run.sh niro [Town]` |
| **MORAI** | 미구현 (AWSIM으로 대체 결정) | — | — | 없음 |

## `run.sh` 전체 명령어

`run.sh` 상단 주석에는 일부만 적혀있어 실제 코드(`case "$CMD" in`)의 전체 목록을 정리:

```bash
# --- CARLA 풀스택 ---
./run.sh                       # Town04 풀스택 기동 (기본, ~4분)
./run.sh Town05                # 다른 타운으로 기동 (Town01~Town10HD)
./run.sh drive                 # 자율주행 출발
./run.sh stop                  # 정지
./run.sh patrol                # 계속 자율주행 반복 (Ctrl-C로 중단)
./run.sh status                # 전체 프로세스 상태
./run.sh gateway [town]        # 게이트웨이만 재시작 (스택은 유지)
./run.sh kill                  # CARLA + 컨테이너 전부 종료
./run.sh killall                # 모든 시뮬(AWSIM/CARLA) 종료 (자원 해제)
./run.sh test                  # 전 타운 자율주행 검증 (~40분) -> docs/town_test_results.md

# --- ROii 4-LiDAR (장애감지·재구성 과제) ---
./run.sh roii low|mid|high [Town]      # 4라이다 실험 모드 (front/rear G32 + L/R Pandar)
CENTERPOINT=1 ./run.sh roii low [Town] # + GPU CenterPoint 객체검출
YOLOX=1 ./run.sh roii low [Town]       # + 전방 카메라 GPU YOLOX 검출

# --- 게이트웨이 수동조작 경로 (docs/gateway_control_path.md) ---
USE_ADAPI_MANUAL=1 ./run.sh gateway [Town]  # 공식 AD API manual-control 경로 (미검증, 옵트인)
                                              # 안 켜면 기본 /external/selected/* 직접발행 경로

# --- 실제 지도 (CARLA 없이 planning_simulator) ---
./run.sh real [/root/autoware_map/<site>]   # 기본: sample-map-planning
./run.sh buildmap [site] [size]             # OSM/NGII -> lanelet2 지도 생성 (기본: pangyo, 1200)
./run.sh realdrive [site]                   # 실제지도 기동 + 연속 자율주행

# --- rosbag 리플레이 / 실차 데이터 ---
./run.sh replay [bag] [town]   # 녹화된 bag 재생 (게이트웨이+rviz+태블릿, 루프)
./run.sh soongsil              # 숭실대 16GB rosbag 이중측위 데모 (전용 앱 com.keti.soongsil)
./run.sh multimode [Town]      # 숭실대 멀티모드(듀얼 측위) 라이브 데모

# --- 실차 구성 (Niro) ---
./run.sh niro [Town]           # Ouster OS2-128 단일 라이다 + 이중측위 주행
./run.sh niro-fault            # 라이다 결함 주입 -> GNSS 폴백 시연
./run.sh niro-clear            # 결함 해제

# --- OSM 기반 데모 ---
./run.sh osm [site]            # OSM 지도 기반 데모 (기본: soongsil)

# --- 태블릿 앱 ---
./run.sh app                   # ROii Command 앱 빌드+설치 (기본값)
./run.sh app monitor|task|command   # 앱 종류 지정 빌드+설치
./run.sh mapdaemon             # 태블릿에서 맵 전환(탭) 받아주는 상시 데몬
```

`osm`, `patrol`, `killall`은 `run.sh` 코드에는 있지만 상단 usage 주석엔 빠져있던
항목 — 실제로 동작하는 명령이니 참고. 기본값: `TOWN_DEFAULT=Town04`.

AWSIM은 `run.sh`에 연결되어 있지 않고 `scripts/run_awsim.sh`를 직접 실행해야 한다.

## 태블릿 앱 목록

이 레포 안에 있는 것과, 레포 밖(`/home/kim/`)에 있는 실제 운용 앱이 섞여있다.

| 앱 | 위치 | 패키지 | 용도 | 빌드/실행 |
|---|---|---|---|---|
| **ROii Command** (메인, 운용중) | `/home/kim/roii_command` (레포 밖) | `com.keti.roii.command` | 자율주행 tap-to-go, 수동조작(조이스틱/틸트), 3D 서라운드 대시보드 | `./run.sh app` 또는 `./run.sh app command` |
| ROii Monitor | `/home/kim/roii_monitor` (레포 밖) | `com.keti.roii.monitor` | 모니터링 전용 | `./run.sh app monitor` |
| ROii Task | `/home/kim/roii_task` (레포 밖) | `com.keti.roii.task` | 장애 감지/재구성 태스크 뷰 | `./run.sh app task` |
| Multimode Autoware Monitor | `app/multimode_autoware_monitor` | `com.example.multimode_autoware_monitor` | 멀티모드(듀얼측위) 상태 모니터 | `cd app/multimode_autoware_monitor && flutter build apk --release` |
| AWSIM Tesla | `awsim_tesla` | `com.keti.awsim_tesla` | AWSIM/신주쿠 백엔드용 Tesla 스타일 대시보드 | `cd awsim_tesla && flutter build apk --release` |
| Niro Command | `niro_command` | `com.keti.niro_command` | Niro 실차 구성 듀얼측위 제어/조이스틱 | `cd niro_command && flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk` |
| Soongsil HMI | `soongsil/soongsil_hmi` | `com.keti.soongsil` | 숭실대 rosbag 리플레이 전용 (LiDAR↔GNSS 편차 실시간 표시) | `./run.sh soongsil`이 자동 빌드/설치/실행 |

모든 앱은 동일한 게이트웨이 프로토콜(`ws://<PC-IP>:8765/ws`)을 사용 —
명령어 전체 목록은 `docs/gateway_commands.md` 참고.

## 관련 문서

- `README.md` — CARLA 백엔드 빠른 시작, 트러블슈팅 로그
- `docs/roii_lidar_carla_autoware.md` — ROii 4-LiDAR 상세 (센서 스펙, 커버리지 조사)
- `docs/roii_fault_reconfig.md` — ROii 장애감지·재구성 시스템 구조 (6개 노드 역할, 데이터
  흐름, sensor_mapping 파일 두 계열 구분)
- `docs/gateway_commands.md` — WebSocket 게이트웨이 명령어 레퍼런스
- `docs/gateway_control_path.md` — 수동조작(teleop) 제어경로: 공식 Autoware 배선 vs 실제
  구현, 양쪽 백엔드(CARLA/AWSIM)가 왜 게이트를 바이패스하게 됐는지 히스토리 + 근본원인
- `docs/awsim_modding_investigation.md` — AWSIM 모딩(새 맵/ROii 4-LiDAR) 가능성 조사:
  바이너리 직접 모딩 불가 확인, 유니티 소스 저장소 현황, 필요 절차, 카를라 대안 비교
- `docs/awsim_setup.md` — AWSIM 백엔드 설정 및 현재 막힌 지점
- `docs/niro_system.md` — Niro 실차 구성 (듀얼 측위, 실제 지도)
- `docs/autoware_carla_integration.md` — CARLA 통합 전체 디버깅 히스토리
- `docs/town_test_results.md` — 타운별 자율주행 검증 결과
- `docs/versions.md` — 전체 버전 매트릭스 (드라이버/OS/ROS2/시뮬레이터/앱), 다른 머신에
  재현할 때 필요한 버전 체크리스트
