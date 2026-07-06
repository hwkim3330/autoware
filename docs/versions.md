# 버전 매트릭스 (다른 머신에서 재현하려면)

이 프로젝트는 여러 시뮬레이터/드라이버 버전이 서로 얽혀있어서(특히 CARLA↔NVIDIA
드라이버, AWSIM↔ROS2 배포판) 버전이 하나만 틀려도 안 돌아가는 경우가 많다.
**다른 장비에 그대로 옮기거나 새로 설치할 때는 이 표의 버전을 그대로 맞춰야 한다.**
(실측 확인: 2026-07-06, 이 머신 기준)

## 호스트 (물리 머신)

| 항목 | 버전 | 확인 명령 |
|---|---|---|
| OS | Ubuntu 24.04.4 LTS (Noble) | `lsb_release -a` |
| NVIDIA 드라이버 | **535.309.01** (고정 필요 — 아래 "왜 535" 참고) | `nvidia-smi --query-gpu=driver_version --format=csv,noheader` |
| CUDA | 12.2 | `nvidia-smi \| grep CUDA` |
| GPU | RTX 3090 (24GB) | `nvidia-smi --query-gpu=name --format=csv,noheader` |
| Docker | 29.1.3 | `docker --version` |
| 호스트 ROS2 | **Jazzy** (컨테이너는 Humble — 아래 참고) | `echo $ROS_DISTRO` |
| Flutter | 3.44.1 (stable) | `flutter --version` |
| Git | 2.43.0 | `git --version` |
| gh CLI | 2.45.0 | `gh --version` |
| adb | 1.0.41 | `adb --version` |
| Python3 (호스트) | 3.12.3 | `python3 --version` |

## `autoware` 컨테이너 (Docker)

| 항목 | 버전 |
|---|---|
| 베이스 이미지 | `ghcr.io/autowarefoundation/autoware:universe-cuda` |
| 커밋된 실행 이미지 | `autoware-shm:latest` (호스트 `/dev/shm` 공유 + `--ipc=host` 설정 포함, FastDDS SHM 에러 방지용) |
| OS (컨테이너 내부) | Ubuntu 22.04 (Jammy) |
| ROS2 | **Humble** |
| Autoware | `autoware_launch` 패키지 버전 0.50.0 |
| Vulkan (컨테이너 내부, AWSIM 렌더링용) | 1.3.204 (`vulkan-tools mesa-vulkan-drivers libvulkan1` apt로 설치) |

## 시뮬레이터

| 항목 | 버전 | 위치 |
|---|---|---|
| **CARLA** | **0.9.16** (Python API + 바이너리 둘 다) | `/opt/carla-simulator/`, pip `carla==0.9.16` |
| **AWSIM** | AWSIM-Demo **v2.0.1** (autowarefoundation/AWSIM, Unity **6000.0.34f1**로 빌드됨) | `~/AWSIM/AWSIM-Demo/`, 컨테이너 내 `/opt/awsim/AWSIM-Demo/` |
| AWSIM-Labs (사용 안 함, 참고용만 보관) | v1.6.1 | `~/AWSIM/awsim_labs/` — **2026-01-11 archived, 더 이상 유지보수 안 됨.** 새로 설치 시 이거 말고 mainline AWSIM 쓸 것. |

## 왜 이 버전들인가

- **NVIDIA 535**: CARLA 0.9.16(UE4.26 기반)이 550+ 드라이버에서 Vulkan RHI가 멈추는
  증상이 이 머신에서 재현됨. 단, 이게 CARLA 공식 문서에 나온 사실은 아니고(공식
  문서엔 드라이버 버전 요구사항 자체가 없음) 이 머신에서 직접 확인한 경험적 결과 —
  다른 머신에서는 다를 수 있음 (`docs/roii_lidar_carla_autoware.md` 참고).
  **주의**: 공식 AWSIM은 드라이버 570+ 권장이라 두 시뮬레이터가 요구사항이 충돌함 —
  한 머신에서 둘 다 쓰려면 535로 통일하고 AWSIM이 되는 만큼만 쓰거나, 시뮬레이터별로
  머신/드라이버를 분리해야 함.
- **호스트 Jazzy / 컨테이너 Humble**: AWSIM 번들 ROS2(ros2-for-unity)가 Humble 전용
  빌드라서, 호스트(Jazzy)와 라이브러리 버전이 안 맞아 세그폴트함. 그래서 AWSIM을
  호스트가 아니라 **컨테이너 안에서** 직접 실행하는 구조로 만듦 (`docs/awsim_setup.md`).
- **AWSIM-Demo v2.0.1, Unity 6000.0.34f1**: 바이너리 자체(`globalgamemanagers`)에서
  직접 문자열로 확인한 값. 소스에서 새로 빌드할 경우 공식 문서는 Unity
  **6000.0.61f1**을 명시하지만, 지금 쓰는 배포 바이너리는 6000.0.34f1로 빌드되어
  있음 — 소스 재빌드 안 하고 배포 바이너리만 쓸 거면 이 차이는 무관.

## 태블릿 앱 (Flutter)

전부 Flutter 3.44.1 기준으로 빌드/테스트됨. 각 앱의 `pubspec.yaml`에 개별
의존성 버전이 고정되어 있음 — 앱별 상세는 `docs/architecture.md`의 태블릿 앱 표 참고.

## 다른 머신에 새로 설치할 때 체크리스트

1. Ubuntu 24.04 (호스트), NVIDIA 드라이버 **정확히 535.x** 설치 (`ubuntu-drivers` 자동설치 X,
   버전 명시해서 설치)
2. Docker 설치 후 `ghcr.io/autowarefoundation/autoware:universe-cuda` pull, 이 프로젝트의
   컨테이너 설정(`--ipc=host -v /dev/shm:/dev/shm`)으로 컨테이너 생성 후 `autoware-shm`으로 커밋
3. CARLA 0.9.16 (바이너리 + `pip install carla==0.9.16`)
4. AWSIM-Demo v2.0.1 바이너리를 `autowarefoundation/AWSIM` 릴리스에서 받아서
   컨테이너 안 `/opt/awsim/AWSIM-Demo/`에 배치 (AWSIM-Labs 말고 mainline 것)
5. Flutter 3.44.1 (`flutter --version`으로 확인, 다르면 `flutter downgrade`/`upgrade`)
6. `gh`/`adb` 최신이면 대체로 무관 (버전에 민감한 부분 아님)
