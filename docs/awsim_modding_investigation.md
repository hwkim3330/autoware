# AWSIM 모딩 조사 (맵 추가, 라이다 추가) — 2026-07-07

`AWSIM-Demo v2.0.1`(지금 쓰는 컴파일된 바이너리, `/opt/awsim/AWSIM-Demo/`)에 새 맵(한국/판교)이나
새 센서(ROii 4라이다)를 넣을 수 있는지 조사한 결과. 결론부터: **바이너리를 직접 모딩하는 건
불가능하고, 유니티 에디터로 다시 빌드하는 것만 가능함.** 근거와 대안을 아래 정리.

## 1. 바이너리 자체 모딩 — 확인된 불가능 (추측 아니고 직접 뜯어봄)

`/opt/awsim/AWSIM-Demo/` 안을 직접 확인:

- `StreamingAssets` 폴더 없음
- `.bundle`/애셋 카탈로그 파일 전혀 없음 (Addressables/AssetBundle 런타임 로딩 안 씀)
- `Assembly-CSharp.dll`(AWSIM 자체 게임코드) 안에 AssetBundle 로딩이나 외부 씬 로딩 관련
  문자열이 **0개** — `UnityEngine.AssetBundleModule.dll`은 있지만 이건 유니티가 기본으로
  넣는 엔진 모듈이고, AWSIM 개발자가 실제로 쓴 적이 없음
- `awsim_config.json`(우리가 `--json_path`로 넘기는 런타임 설정)에 맵/센서 경로 필드 자체가
  없음 — 차량/시간/트래픽 설정만 있음

즉 지금 배포판은 빌드 시점에 모든 콘텐츠(환경 메시, 센서 구성)를 이미 다 구워넣은 고정
바이너리라, 새 맵이든 새 센서든 넣으려면 **유니티 에디터로 다시 빌드**해야 함. 이건 카를라도
똑같음 — UE4/UE5 에디터로 콘텐츠를 "쿠킹"해야 하는 구조는 두 엔진 다 동일 (`docs/gateway_control_path.md`
류의 "일단 되니까 맞는 방법"으로 넘기지 말고 소스/구조 직접 확인하자는 원칙을 여기도 적용함).

## 2. "에디터 없이" 되나? — 절반만 됨

유니티 에디터 **바이너리**는 피할 수 없지만, 사람이 GUI에서 마우스로 클릭하는 작업은 0으로
만들 수 있음:

- Unity는 `-batchmode -executeMethod ClassName.Method` 커맨드라인으로 정적 C# 메서드를
  실행할 수 있음 (표준 CI 빌드 자동화 방식, 문서화 잘 되어있음)
- 씬 조립에 필요한 작업(메시 배치, MeshCollider 추가, Environment 컴포넌트에 MGRS 좌표
  입력, 조명/Volume 추가, 라이다 프리팹 배치)은 전부 `GameObject.AddComponent<T>()`,
  `transform.localPosition = ...` 같은 평범한 C# 한두 줄이라 전부 스크립트화 가능
- 확인한 논문(`arxiv 2508.16856`, AV 시뮬레이션 맵 생성 워크플로우)도 OSM→메시→PCD까지는
  자동화했지만, **유니티 씬 조립 단계는 자동화한 사례가 없음** — 우리가 하면 처음일 수 있음

즉 "에디터 완전히 안 씀"은 불가능하지만 "에디터를 CLI로만 건드리고 사람은 스크립트만 짬"은
가능. 못 하는 건 Unity Editor 바이너리 자체를 배제하는 것 (플레이어가 런타임에 원본 애셋을
못 읽기 때문).

## 3. 시작점 — 소스 저장소가 이미 있음 (맨땅에서 시작 아님)

`autowarefoundation/AWSIM` (구 `tier4/AWSIM`, 계속 관리중, 최근 푸시 2026-05-13) 소스에
우리가 쓰는 컴파일된 데모의 **원본 씬이 그대로** 들어있음:

- `Assets/Awsim/Scenes/AutowareSimulationDemo.unity` — 우리가 쓰는 신주쿠 데모 씬 원본
- `Assets/Awsim/Scenes/PcdGenerationDemo.unity` — 메시에서 PCD 뽑는 전용 씬 (우리
  `environment.obj`로 판교 PCD 재생성/검증하는 데 재사용 가능할 수도)
- `Assets/Awsim/Scenes/IntegrateScenarioSimulatorDemo.unity`

모딩할 땐 바이너리를 역공학하는 게 아니라 **이 소스를 clone해서 저 씬을 직접 열어 수정**하는
게 맞는 방향. AWSIM-Labs(archived) 문서 기준으로는 Lexus 샘플 차량 프리팹에 라이다 슬롯이
3개 있고 2개는 정의만 되고 비활성 상태라고 함 — mainline(`autowarefoundation/AWSIM`)의 Ego
차량 프리팹도 비슷한 구조인지는 아직 직접 확인 안 함 (다음에 소스 clone하면 바로 볼 것).

## 4. 새 릴리즈 없음 — 우리가 쓰는 버전이 이미 최신

`gh api repos/autowarefoundation/AWSIM/releases`로 확인: **v2.0.1(2025-10-31)이 지금도
최신**, 그 이후 태그된 릴리즈 없음 ("맵 업데이트"는 존재 안 함). v1.x/v2.0.0 시절엔 맵이
`Shinjuku-Map.zip`/`.unitypackage`로 따로 배포됐는데, v2.0.1부턴 `AWSIM-Demo.zip`(바이너리)
하나로 통합됨 — 소스 프로젝트에서 그 씬을 직접 열면 되므로 실질적 손해는 없음.

## 5. 새 맵 만들기 — 필요한 재료는 이미 다 있음

공식 워크플로우(AWSIM-Labs "Add Environment" 문서 + arxiv 2508.16856 논문 확인, 2026-07-07)
가 요구하는 파일: **Lanelet2 OSM + PCD + 3D 메시(obj/mtl/png 또는 fbx)**. 우리
`/home/kim/awsim_korea_map/` 파이프라인이 브이월드 데이터로 이미 정확히 이 포맷을 뽑고 있고,
판교/용인구성/강남 3곳이 실제로 생성돼있음 (`/home/kim/autoware_map/pangyo_awsim/` 등,
`aerial.png`=진짜 브이월드 위성사진, `environment.obj`, `lanelet2_map.osm`,
`pointcloud_map.pcd`). 재료 준비는 끝났고 남은 건 유니티 씬 조립 단계뿐.

유니티 씬 조립 절차 (GUI 기준, 스크립트화 대상):
1. `.fbx`(또는 obj) 임포트 → 배치 → prefab unpack
2. Environment 스크립트 컴포넌트 추가 + MGRS 좌표 오프셋 입력 (우리 `.origin` 파일에 이미
   숫자로 있음 — 사람이 눈으로 맞출 필요 없이 그대로 대입 가능)
3. Directional Light, HDRP Volume 추가
4. (선택) NPC 보행자 배치
5. 신호등은 별도 튜토리얼 — 더 손이 감

## 6. 새 라이다(ROii 4개) 추가 — 맵보다 훨씬 쉬움

AWSIM은 라이다에 RGL(Robotec GPU Lidar)을 쓰고, 이미 멀티라이다를 지원하는 구조 (공식 샘플
차량 프리팹에 라이다 슬롯 3개, 그중 2개가 "정의는 돼있는데 비활성"). 라이다 추가 절차:
1. ROS 프레임 계층에 맞는 GameObject 만들기 (`sensor_kit_base_link` → `xxx_base_link`)
2. `Assets/AWSIM/Prefabs/Sensors/RobotecGPULidars`에서 프리팹 드래그
3. Inspector에서 노이즈/레인지/frame_id 설정

맵보다 훨씬 적은 단계 (분 단위). ROii 4라이다(front/rear G32, left/right Pandar)의 정확한
마운트 위치는 카를라에서 이미 실측/검증 끝난 값을 그대로 재사용 (`carla_sensor_kit_description/config/sensor_kit_calibration.yaml`):

| link | x | y | z | roll | pitch | yaw | note |
|---|---|---|---|---|---|---|---|
| `roii_front_g32_base_link` | 2.150 | 0.000 | 1.100 | 0 | 0 | 0 | forward-facing |
| `roii_rear_g32_base_link` | -2.150 | 0.000 | 1.100 | 0 | 0 | π (3.141593) | rear-facing |
| `roii_left_pandar_base_link` | 1.600 | -1.050 | 2.600 | 0 | 0 | 0 | raised from 1.900 — cabin self-occlusion ate ~90-130° of the declared 220° FOV at the lower mount |
| `roii_right_pandar_base_link` | 1.600 | 1.050 | 2.600 | 0 | 0 | π/2 (1.570796) | +90° = pure right-facing |

주의: 유니티는 왼손 Y-up, ROS는 오른손 Z-up — 이 값들을 Transform에 그대로 복붙하면 안 되고
축 변환 필요 (환경 메시도 이미 이 변환을 거쳐서 obj로 나옴, 같은 변환 적용).

ROS2 launch/xacro 쪽 스캐폴딩은 아직 안 만듦 — 존재하지 않는 토픽 구조를 미리 짜는 건
나중에 실제 구현과 안 맞을 위험이 커서 (없는 기능을 위한 미완성 코드), 유니티 쪽 작업이
실제로 시작되면 그때 만들 것.

## 7. 대안 검토 — 카를라

같은 날 카를라 쪽도 같이 조사함 (요약, 상세는 대화 기록):
- 카를라는 `carla.Osm2Odr.convert()` + `client.generate_opendrive_world()`로 **에디터 전혀
  없이** OSM→주행 가능한 맵 변환이 됨. 단, 건물/위성텍스처 없이 **도로만 있는 빈 맵** ("besides
  the road elements, there will be only void" — 공식 문서).
- 카를라 버전: **0.10.0(UE5.5, 2024-12-19)이 최신처럼 보이지만 실제로는 더 안 좋음** —
  공식 블로그가 "아직 work in progress, 기능 마이그레이션 안 끝남" "프레임레이트 24-25 FPS"
  "16GB+ VRAM 권장"이라고 직접 밝힘. 우리가 쓰는 **0.9.16(2025-09-16)이 0.10.0보다 나중에
  나온, UE4 안정 라인의 최신판**이라 이미 최선의 버전 쓰고 있음 — 새로 받을 필요 없음.

## 결론 / 다음 결정

- 진짜 판교처럼 보이는 맵 + 4라이다: 유니티 필요 (Hub+Editor+AWSIM 소스, 수 GB 다운로드),
  하지만 스크립트로 사람 클릭 0번 가능, 재료(맵 데이터+마운트 스펙)는 이미 다 있음
- 빠르고 에디터 없이: 카를라 OpenDRIVE, 근데 건물 없는 깨끗한 도로만
- 유니티 설치는 아직 진행 안 함 — 진행 여부는 사용자 결정 대기
