#!/bin/bash
# ============================================================================
# ROii Autoware — single entry point.   사용법:
#
#   ./run.sh                # Town04 자율주행 풀스택 (CARLA+Autoware+게이트웨이+rviz)
#   ./run.sh Town05         # 다른 타운으로
#   ./run.sh real           # 실제 지도 (CARLA 없이, planning simulator)
#   ./run.sh status         # 전체 프로세스 상태 한눈에
#   ./run.sh drive          # 자율주행 출발 (태블릿 DRIVE 버튼과 동일)
#   ./run.sh stop           # 정지
#   ./run.sh app            # 태블릿 앱 빌드+설치 (USB)
#   ./run.sh test           # 전 타운 자율주행 검증 (~40분)
#   ./run.sh kill           # 전부 종료 (CARLA + 컨테이너 스택)
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")" && pwd)"
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
DEX() { SUDO docker exec autoware bash -lc "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; $1"; }

case "${1:-Town04}" in
  status)  exec bash "$REPO/scripts/status.sh" ;;
  real)    exec bash "$REPO/scripts/run_real_map_sim.sh" "${2:-/root/autoware_map/sample-map-planning}" ;;
  test)    exec bash "$REPO/scripts/test_all_towns.sh" ;;
  drive)   DEX "python3 /root/drive_monitor.py drive" ;;
  stop)    DEX "python3 /root/drive_monitor.py stop 2>/dev/null | head -3" ;;
  app)
    cd /home/kim/roii_autoware_monitor
    export PATH="$PATH:/home/kim/flutter/bin"
    flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk
    adb reverse tcp:8765 tcp:8765 && echo "앱 설치+USB 연결 완료"
    ;;
  kill)
    SUDO pkill -9 -f CarlaUE4-Linux-Shipping; SUDO docker restart autoware >/dev/null
    echo "정리 완료 (CARLA 종료, 컨테이너 재시작)"
    ;;
  Town*)   exec bash "$REPO/scripts/run_localization_demo.sh" "$1" ;;
  *)       grep -E "^#   ./run.sh" "$0" | sed 's/^# *//'; exit 1 ;;
esac
