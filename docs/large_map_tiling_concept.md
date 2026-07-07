# 대규모 맵(여러 지역/한국 전체) — 오토웨어 쪽 타일 스트리밍 구상

"한국을 하나의 맵으로" 질문에서 나온 후속 — 결론: 하나의 통짜 맵은 카를라(100km² 한계, Large
Map도 안 됨)든 오토웨어(포인트클라우드 하나로는 메모리/실시간 매칭 불가능)든 안 됨. 근데
오토웨어 쪽엔 "게임식 로딩"(현재 위치 근처 타일만 로드, 멀어지면 언로드)이 **이미 공식 기능으로
있음** — 만들 필요 없이 그냥 그 위에 우리 맵 생성 파이프라인을 맞추면 됨.

## 공식 기능: `autoware_map_loader`의 partial/differential pointcloud 로딩

소스: `autowarefoundation/autoware_core` (map_loader가 `autoware_universe`에서 이 별도
"core" 저장소로 옮겨감, 검색 시 이 차이 때문에 헷갈릴 수 있음 — 주의) `map/autoware_map_loader/README.md`.

- **분할 규칙**: 포인트클라우드 맵을 x/y축에 평행한 직선으로만 분할(대각선/곡선 불가), 축마다
  분할 크기 동일, **권장 분할 크기는 20m × 20m** (100m 넘으면 NDT 동적 로딩 성능에 안 좋은 영향).
- **메타데이터 형식** (`pointcloud_map_metadata.yaml`):
  ```yaml
  x_resolution: 20.0
  y_resolution: 20.0
  A.pcd: [1200, 2500]   # x: 1200~1220, y: 2500~2520
  B.pcd: [1220, 2500]
  ...
  ```
- **디렉토리 구조**: `pointcloud_map.pcd/` 밑에 타일 파일들 + `pointcloud_map_metadata.yaml`
  + `lanelet2_map.osm`(도로 그래프는 안 나눔 — 텍스트/그래프라 큰 지역도 상대적으로 가벼움)
  + `map_projector_info.yaml`.
- **서비스**: `service/get_partial_pcd_map`(쿼리 영역과 겹치는 타일들만 반환),
  `service/get_selected_pcd_map` — `autoware_ndt_scan_matcher`가 이걸 써서 **현재 위치 근처
  타일만 메모리에 들고, 멀어진 타일은 내림** — 정확히 "게임 로딩방식"에서 말한 그거임.
- **분할 도구**: `autoware_tools`의 `autoware_pointcloud_divider` — 하나의 큰 PCD를 넣으면
  자동으로 20m 그리드로 쪼개고 `metadata.yaml`까지 생성해줌.

## 우리 파이프라인에 적용한다면

지금 `/home/kim/awsim_korea_map/gen_real_map.py`는 지역 하나당 `pointcloud_map.pcd` **파일
하나**를 만듦 (판교 900m×900m, ~100만 포인트). 이걸 여러 지역으로 확장하려면 두 경로:

1. **후처리**: 지역별로 지금처럼 만들고, `autoware_pointcloud_divider`에 통과시켜 20m 타일로
   쪼갬. 기존 스크립트 안 건드려도 됨, 별도 단계 추가.
2. **직접 생성**: `gen_real_map.py`의 pcd 쓰기 부분(`write_pcd`)을 20m 그리드 버킷으로 나눠서
   여러 `.pcd` 파일 + `metadata.yaml`을 직접 출력하도록 고침. 지역이 넓어질수록(여러 지역을
   서로 이어 붙인 "지역 묶음" 맵을 만들 경우) 유리함.

lanelet2(`write_lanelet2`)는 그대로 하나의 파일로 둬도 됨 — 도로 그래프는 그래프 탐색이라
포인트클라우드처럼 메모리에 안 부담됨, 문서에도 분할 규칙이 pointcloud에만 있음.

## 범위: 이걸로도 카를라 쪽 한계는 안 풀림

이 타일링은 **오토웨어의 측위/플래닝 쪽 문제만** 해결함 — 여러 지역을 이어붙여도 오토웨어는
문제없이 커버 가능. 근데 카를라(`gen_carla_map.py`)는 별개 문제라 안 풀림: OpenDRIVE
스탠드얼론 모드는 타일링 자체가 없고, Large Map조차 100km² 한계 + UE4 콘텐츠 저작(에디터) 필요.
즉 "오토웨어는 여러 지역 이어붙여서 넓게" 가능해져도, 그 넓은 지역을 카를라 안에서 눈으로
보면서 달리는 건 여전히 안 됨 — 각 지역을 개별 카를라 월드로 따로 로드해야 함.

## 결론 (구상 단계, 구현 안 함)

- 지금처럼 지역별 개별 맵(판교/용인/강남 각각)을 유지하는 게 현실적으로 맞는 방향.
- "여러 지역을 하나로 이어서 넓게" 필요해지면: `autoware_pointcloud_divider`로 후처리 분할이
  제일 간단한 시작점 (기존 스크립트 안 고쳐도 됨).
- 카를라 쪽은 어차피 지역별로 따로 로드하는 구조가 유지되므로, 오토웨어만 타일링해도 두 파이프
  라인의 "지역 단위" 개념 자체는 안 어긋남.
