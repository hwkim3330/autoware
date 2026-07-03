# ROii 4-LiDAR on CARLA + Autoware (experimental layer)

기존 1-LiDAR 실행 경로(`./run.sh Town04`)는 그대로 보존되고, 이 문서의 모든
구성은 **별도 스크립트/설정/노드/패널**로 추가된다 (Autoware core 무수정,
ROS topic/service/node/RViz plugin 계층 확장).

## 실행

```bash
./scripts/run_roii_lidar_low.sh  Town04    # 안정성/토픽/TF/concat 검증용
./scripts/run_roii_lidar_mid.sh  Town04    # 기본 개발·주행 테스트
./scripts/run_roii_lidar_high.sh Town04    # ROii 커버리지 근사 (CPU 부하 큼)
# 또는: ./run.sh roii low|mid|high [Town]
bash scripts/check_roii_lidar.sh           # 검증 일괄 체크
```

## 센서 구성 (모델링 기준)

| 센서 | 모델 기준 | CH | Range | H-FOV | V-FOV | 프레임 |
|---|---|---|---|---|---|---|
| Front | AutoL G32 계열 | 32 | 135 m (low) | 135° | -5°~+5° | `roii_front_g32` |
| Rear | AutoL G32 계열 | 32 | 135 m (low) | 135° | -5°~+5° | `roii_rear_g32` |
| Left | Hesai Pandar40P 계열 | 40 | 110 m (low) | 220°* | -25°~+15° | `roii_left_pandar` |
| Right | Hesai Pandar40P 계열 | 40 | 110 m (low) | 220°* | -25°~+15° | `roii_right_pandar` |

\* 공식 스펙(autoa2z.co.kr/ROII)은 측면 180°지만, 전/후방 G32(135°)와 의도적으로
겹치도록 220°로 넓혀서 사각을 최대한 줄임 (겹침 자체는 정상 — 아래 "커버리지
조사 결과" 참고).

차량 치수: L 4.900 / W 2.095 / H 2.660 m, wheel_base 3.300 m, max 40 km/h.
**장착 위치는 임시값**(실측 CAD 아님) — `config/roii_sensor_spec.yaml` 참조.
front (2.15, 0, 1.10, 0°) / rear (-2.15, 0, 1.10, 180°) /
left (1.60, -1.05, 2.60, -90°) / right (1.60, 1.05, 2.60, 90°).

y 부호는 이 프로젝트의 base_link 관습(+y = 차량 우측, ROS REP103 표준과 다름,
CARLA `get_right_vector()`로 실측 검증됨)을 따른다. yaw는 센서 이름과 실제
바라보는 방향이 일치하도록 순수 좌/우(±90°)로 설정 — 대각선(45°) 마운트는
실제로는 아무 이득이 없었다 (아래 참고).

### 커버리지 조사 결과 (2026-07-02 세션)

4-LiDAR 합산 커버리지를 각도 히스토그램(5° bin, `/sensing/lidar/concatenated/pointcloud`
기준)으로 반복 측정하며 여러 마운트 파라미터를 시도한 결과:

| 시도 | 효과 |
|---|---|
| 좌우 위치가 물리적으로 뒤바뀐 버그 수정 | 실제 버그, 수정 (커밋 `706ab7b`) |
| Pandar 높이 1.35 → 1.90m | **효과 있음** — REAR 방향 자기폐색(self-occlusion) 갭 해소, 265→310/360° |
| Pandar 높이 1.90 → 2.60m (거의 지붕 높이) | 효과 불명확, 측정마다 결과가 다름 (지형 영향 큼) |
| Pandar y 오프셋 1.05 → 1.25 → 3.0 (진단용) | 효과 없음 |
| Pandar yaw 45° → 90° → 60°(진단용) | 60°는 갭이 25°→55°로 오히려 악화 → 90°(순수 좌우)가 최선 |
| Pandar FOV 220° → 260°(진단용) | 효과 없음 |
| G32 FOV 135° → 170°(시도 후 135°로 원복) | 효과 없음, 공식 스펙값(135°)으로 최종 확정 |

**결론**: 90-115°/270-305° 부근(차량 기준, 0=전방·90=우측·180=후방·270=좌측)에
남는 약 40°의 잔여 사각은, 라이브 CARLA 액터에서 `horizontal_fov` 파라미터가
정확히 적용됨을 직접 확인했음에도(설정 문제 아님) 사라지지 않는, 차체 자기폐색과
지형이 결합된 근본적 한계다. 최초의 높이 조정(1.35→1.90m) 외에는 어떤 마운트
파라미터 조정도 유의미한 추가 개선을 만들지 못했다. RViz에서 좌우 비대칭하게
보이는 것(한쪽은 넓게 퍼진 팬 모양, 다른 쪽은 얇은 선)은 대부분 설정이 아니라
그 위치의 실제 지형(가까운 반사체 유무) 차이 때문이다 — `docs/gateway_commands.md`의
`fault` 명령으로 센서를 하나씩 꺼보면 좌/우가 각각 올바른 쪽(우측 센서 끄면
전방-우측 소실, 좌측 센서 끄면 후방-좌측 소실)만 잃는 것으로 재확인 가능.

## low / mid / high 프로파일

CARLA의 ray-cast LiDAR는 points_per_second에 CPU가 비례하므로 가변 프로파일을
둔다. LOW는 파이프라인 검증, MID는 일상 개발, HIGH는 실센서 커버리지 근사가
목적이다 (수치: `config/roii_sensor_spec.yaml`의 `profiles`).
Autoware 입력 다운샘플은 localization util의 voxel downsampler가 담당하므로
HIGH에서도 NDT 입력은 자동으로 정리된다.

CARLA가 `horizontal_fov`를 지원하므로 G32 135°는 네이티브로 생성된다
(`carla_wrapper.py` 패치). 미지원 버전이라면 360°로 생성 후 전/후 135°만
통과시키는 crop 필터로 대체한다 (fallback, 현재 불필요).

## 토픽 흐름

```
interface ──/sensing/lidar/<name>/pointcloud_raw──► fault_injector
  injector ──/sensing/lidar/<name>/pointcloud_before_sync──► concatenate
  concat   ──/sensing/lidar/concatenated/pointcloud──► (기존 NDT 경로 재사용)
```
`<name>` ∈ front_g32 / rear_g32 / left_pandar / right_pandar.

## Fault injector (`ros/roii_lidar_fault_injector.py`)

명령: `/roii/fault_injector/command` (std_msgs/String, JSON)

```json
{"sensor":"front_g32","mode":"drop","duration":10.0}
{"sensor":"left_pandar","mode":"stamp_offset","offset_sec":-5.0,"duration":10.0}
{"sensor":"front_g32","mode":"delay","delay_ms":500,"duration":10.0}
{"sensor":"front_g32","mode":"downsample","ratio":0.1,"duration":10.0}
{"sensor":"all","mode":"normal"}
```
모드: normal · drop · delay · downsample · stamp_zero · stamp_offset · freeze.
duration 경과 시 자동 normal 복귀. 상태: `/roii/fault_injector/status` (1 Hz).

## Health monitor (`ros/roii_lidar_health_monitor.py`)

발행: `/diagnostics` (DiagnosticArray) + `/roii/lidar_health` (JSON).

판단 기준: timeout >1 s → STALE / hz <5 WARN, <2 ERROR /
|now−stamp| >0.5 s → ERROR / TF 조회 실패 → ERROR / 포인트 수 부족 → WARN.

집계 정책: front ERROR → ERROR / rear → WARN / side 1개 → DEGRADED /
side 2개 → ERROR / 총 2개 이상 → ERROR.

## RViz 패널 (`rviz_plugins/roii_sensor_fault_panel`)

`ROiiSensorFaultPanel` — 센서별 상태(OK 초록/WARN 노랑/ERROR 빨강/STALE 회색),
hz·stamp·TF·points 표시, 센서별 Normal/Drop/Delay/StampErr/LowPts 버튼,
Global(All Normal/All Drop/All StampErr/Trigger Emergency/Refresh).
명령은 앱과 동일한 `/roii/fault_injector/command`로 publish.
Emergency 토픽/서비스명은 패널 설정값(기본 비연결, Phase C에서 연결).

빌드(컨테이너 안 1회):
```bash
./scripts/build_roii_rviz_panel.sh
# 이후 ROii rviz는 rviz/roii_lidar_fault.rviz 설정으로 자동 로드
```

## 앱

관제 앱(ROii Multimode 관제)에 **ROii Sensor Fault** 화면 추가 — 4센서
상태/hz/stamp/TF/points + 센서별·전체 고장주입 버튼. 게이트웨이 명령:
```json
{"cmd":"fault","sensor":"front_g32","mode":"drop","duration":10}
{"cmd":"fault","sensor":"all","mode":"normal"}
{"cmd":"trigger_emergency"}
```
게이트웨이는 `/roii/lidar_health`를 프레임에 중계한다 (`roii` 필드).

## MRM 연결 단계

- **Phase A (현재)**: 상태 발행/표시만 — /diagnostics + /roii/lidar_health.
- **Phase B**: ERROR 시 패널/앱 강조 + Trigger Emergency 수동 테스트.
- **Phase C**: 런타임에 fail-safe 토픽/서비스를 탐색해 설정값으로 연결,
  센서 ERROR → comfortable/emergency stop을 외부 monitor에서 트리거.

## 검증

`scripts/check_roii_lidar.sh` — 4토픽 존재/hz/stampΔ/TF, concat hz,
kinematic_state, lidar_health, diagnostics, RViz 라이브러리/등록 확인.

## 현재 한계

CARLA ray-cast LiDAR는 실제 G32/Pandar의 빔 패턴·intensity 모델·multi-return·
비선형 vertical 분포를 재현하지 못한다. 채널/레인지/FOV/포인트율 수준의
근사이며, 인지·측위 부하 및 고장 대응 로직 검증용으로 사용한다.
