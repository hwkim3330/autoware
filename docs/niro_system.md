# Niro 자율주행 데모 — 시스템 문서

KETI Niro 실차 구성을 CARLA + Autoware로 시뮬레이션하고, 태블릿 앱(`niro_command`)으로
주행·이중측위(LiDAR/GNSS)·결함 페일오버를 제어/시각화하는 시스템. 실제 지도(숭실대/판교)도
지원하려는 작업 포함.

## 1. 한눈에 보기 — 무엇이 되고 무엇이 안 되나

| 구성 | 상태 | 실행 |
|---|---|---|
| **CARLA Town + Autoware + 앱 + rviz + 자율주행** | ✅ **검증됨** (28km/h, 이중측위, 결함 페일오버) | `./run.sh niro Town04` |
| 태블릿 앱 `niro_command` (이중측위 패널 + 수동주행 + OSM 베이스맵) | ✅ 빌드/설치됨 | `cd ~/niro_command && flutter build apk --release && adb install -r ...` |
| 실제 지도 OSM→OpenDRIVE 변환 | ✅ (숭실대 338도로, 판교 691도로) | `scripts/osm_to_carla.py <site>` |
| 실제 지도 → CARLA 적재 | ❌ **이 CARLA 빌드의 OpenDRIVE 로더 고장** (네이티브 맵도 거부) | — |
| 실제 지도 planning_simulator 측위 | ✅ (lanelet2 로드 + 차선 위 측위) | `./run.sh real /root/autoware_map/<site>` |
| 실제 지도 **자율주행(라우팅)** | ⚠️ **미완** — 변환 lanelet2의 라우팅 그래프 연결성 부족 | (변환기 개선 필요) |
| NGII 정밀도로지도 → lanelet2 | ✅ 변환·로드·측위 (판교 618 lanelet) / ⚠️ 라우팅 연결성 | `scripts/ngii_to_lanelet2.py` |

## 2. CARLA Town 데모 (검증된 메인 경로)

```bash
./run.sh niro Town04      # 풀스택: CARLA + Autoware(이중측위) + niro_bridge + 게이트웨이 + rviz
./run.sh drive            # 자율주행 출발 (또는 태블릿 DRIVE)
./run.sh niro-fault       # 라이다 결함 주입 → GNSS 폴백 (가중치 0.5/0.5→0/1)
./run.sh niro-clear       # 결함 해제
./run.sh app              # (구) ROii Command 앱. 새 앱은 niro_command 참고
./run.sh kill             # 전부 종료
```

- **이중측위**: `multimode_supervisor.py`가 EKF 측위원을 NDT↔GNSS로 선택(실주행). `niro_bridge.py`가
  문서 스펙의 Pose Merger(가중 융합·전환 램프·점프 측정)를 CARLA 토픽 위에서 텔레메트리로 구동
  → `/niro/multimode/*` → 게이트웨이 → 앱.
- **단일 Ouster OS2-128** 구성(`ros/objects_niro.json`). 기본 1-라이다 경로 = Ouster 대역.
- **핵심 함정**: `transform_map_to_base_link` 진단 노드가 patrol 재경로 중 TF 끊김으로 ERROR에
  박혀 autonomous 가용성을 막음 → NIRO 경로에서 해당 진단 leaf 제거(localization.yaml).

## 3. 태블릿 앱 `niro_command` (신규, /home/kim/niro_command)

- package `com.keti.niro_command` (기존 `roii_command`과 별개).
- 게이트웨이 WebSocket(`ws://<PC>:8765/ws`, USB는 `adb reverse tcp:8765 tcp:8765`).
- **이중측위 패널**: LiDAR/GNSS 가중치 바(애니메이션), 센서 점등, 격차, 전환 이벤트, MRM 래더, 결함 토글.
- **수동주행**: MANUAL 토글 → 조향 스틱/틸트 + ACCEL/REVERSE 페달 → `{cmd:teleop,v,steer}`.
- **지도**: `site`(지오원점)가 오면 **OpenStreetMap 타일 + ego/경로 오버레이**(`osm_map_view.dart`),
  아니면 합성 MapView. ⚠️ **OSM 타일은 태블릿 자체 인터넷(wifi) 필요** — 없으면 차량만 보이고
  배경이 빈다(아래 트러블슈팅).
- **빌드 함정**: 새 flutter create가 Gradle 9.1/AGP 9.0/Kotlin 2.3 → 빌드 실패. 작동 버전
  Gradle 8.12/AGP 8.9.1/Kotlin 2.1.0으로 맞춰야 함(gradle-wrapper.properties + settings.gradle).

## 4. 실제 지도 파이프라인

### 4a. OSM (무료, 전 세계) → 지도
```bash
python3 scripts/osm_to_carla.py soongsil   # Overpass→OpenDRIVE(.xodr)  ~/autoware_map/osm/
python3 scripts/osm_to_lanelet2.py soongsil # OSM→lanelet2  ~/autoware_map/<site>/
```
- PROJ 수정: `PROJ_LIB`/`PROJ_DATA` = pyproj proj.db, 사이트 중심 tmerc 투영(local 좌표).
- 한계: OSM 중심선 기반이라 차선 토폴로지가 추정 → **라우팅 그래프 연결성 부족**.

### 4b. NGII 정밀도로지도 (국토정보플랫폼, 정밀) → lanelet2
```bash
# USB의 (B110)정밀도로지도_*.zip → ~/autoware_map/ngii/ 복사 후 해당 사이트 .shp 추출
python3 scripts/ngii_to_lanelet2.py ~/autoware_map/ngii/pangyo_ngii pangyo_ngii
```
- 입력: A2_LINK(차선 중심선+FromNode/ToNode 그래프), B2_SURFACELINEMARK(차선 경계 페인트),
  A1_NODE. CRS = UTM-K(EPSG:5179) → local 미터.
- 판교: 618 lanelet 변환·로드·측위 OK. ⚠️ 라우팅: 경계 매칭/연결성 추가 정교화 필요
  (B2 마크를 링크 구간으로 클리핑 + 공유 노드 연결).

### 4c. planning_simulator로 실제 지도 주행
```bash
./run.sh real /root/autoware_map/pangyo_ngii   # CARLA 없이 lanelet2 위 주행(완전측위)
```
- 게이트웨이가 `~/autoware_map/<site>/<x>.origin`의 위경도를 앱에 전달(OSM 오버레이용).

## 5. 트러블슈팅

- **앱에 차량만 보이고 지도가 안 뜸**: 태블릿이 인터넷(wifi) 없어 OSM 타일 미로딩.
  → 태블릿 wifi 연결, 또는 도로 벡터 오버레이만으로 표시(개선 예정).
- **CARLA 맵으로 실제지도 안 됨**: 이 빌드의 `generate_opendrive_world`가 고장(네이티브 맵도
  "could not be correctly parsed"). 실제지도는 planning_simulator 경로 사용.
- **자율주행 출발 안 함(avail=False)**: `/diagnostics`에서 ERROR leaf 확인. 흔한 원인 =
  `transform_map_to_base_link` 진단 wedge, `duplicated_node_checker`, traffic_light 모니터.
- **실제지도 라우팅 안 됨**: 변환 lanelet2의 라우팅 그래프 미연결. 정식 해법 = TIER IV
  Vector Map Builder 또는 변환기 연결성 보강.

## 6. 다음 작업
1. NGII 변환기 라우팅 연결성 보강(경계 클리핑 + 노드 공유) → 판교 실제지도 자율주행.
2. 앱 OSM 뷰에 도로 벡터 오버레이(오프라인에서도 지도 표시) + UTM-K 격자수렴 보정.
3. (선택) CARLA 실제맵 = RoadRunner/UE4 베이크 필요(이 박스 불가).
