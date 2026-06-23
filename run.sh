#!/bin/bash
# ============================================================================
# ROii Autoware — single entry point.
#
#   ./run.sh                 # Town04 풀스택 기동 (CARLA+Autoware+게이트웨이+rviz)
#   ./run.sh Town05          # 다른 타운으로 기동
#   ./run.sh drive           # 자율주행 출발 (태블릿 DRIVE 버튼과 동일)
#   ./run.sh stop            # 정지
#   ./run.sh gateway         # 게이트웨이만 (재)시작 (앱 연결용)
#   ./run.sh status          # 전체 프로세스 상태 한눈에
#   ./run.sh kill            # 전부 종료 (CARLA + 컨테이너) — 전기 절약
#   ./run.sh app             # 태블릿 앱(ROii Command) 빌드+설치 (USB)
#   ./run.sh mapdaemon       # 태블릿 맵-전환 데몬 (탭으로 맵 바꾸려면 상시 실행)
#   ./run.sh real            # 실제 지도 (CARLA 없이, planning simulator)
#   ./run.sh test            # 전 타운 자율주행 검증 (~40분)
#   ./run.sh roii low|mid|high [Town]   # ROii 4라이다 실험 모드
#   ./run.sh multimode [Town]           # 숭실대 멀티모드
#   ./run.sh niro [Town]                # Niro 실차 구성(단일 Ouster OS2-128 + 이중측위) 주행
#   ./run.sh niro-fault / niro-clear    # 라이다 결함 주입/해제 (GNSS 폴백 시연)
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")" && pwd)"
TOWN_DEFAULT=Town04
SPAWN_DEFAULT="-508.8, 290.4, 0.5, 0.0, 0.0, 75.0"
SUDO() { echo 1 | sudo -S "$@" 2>/dev/null; }
DEX() { SUDO docker exec autoware bash -lc "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; source /opt/autoware/setup.bash; $1"; }

CMD="${1:-$TOWN_DEFAULT}"
case "$CMD" in
  status)  exec bash "$REPO/scripts/status.sh" ;;
  real)    exec bash "$REPO/scripts/run_real_map_sim.sh" "${2:-/root/autoware_map/sample-map-planning}" ;;
  buildmap)  exec bash "$REPO/scripts/build_realmap.sh" "${2:-pangyo}" "${3:-1200}" ;;
  realdrive) # real-map bring-up + continuous autonomous driving (planning_sim)
    SITE="${2:-pangyo}"
    bash "$REPO/scripts/run_real_map_sim.sh" "/root/autoware_map/$SITE"
    SUDO docker cp "$REPO/ros/auto_realmap_drive.py" autoware:/root/auto_realmap_drive.py >/dev/null 2>&1
    DEX "python3 -u /root/auto_realmap_drive.py $SITE" ;;
  test)    exec bash "$REPO/scripts/test_all_towns.sh" ;;
  replay)  exec bash "$REPO/scripts/run_replay.sh" "${2:-/root/replay/recorded}" "${3:-Town04}" ;;
  drive)   DEX "python3 /root/drive_monitor.py drive" ;;
  patrol)  # continuous autonomous driving: re-drives on arrival/stuck (Ctrl-C to stop)
    SUDO docker cp "$REPO/ros/patrol_loop.py" autoware:/root/patrol_loop.py
    DEX "python3 -u /root/patrol_loop.py" ;;
  stop)    DEX "python3 /root/drive_monitor.py stop 2>/dev/null | head -3" ;;
  gateway)
    # restart just the ROS<->WebSocket gateway (stack stays up)
    SUDO docker cp "$REPO/ros/ros_ws_gateway.py" autoware:/root/ros_ws_gateway.py
    SUDO docker exec autoware bash -c 'pkill -9 -f ros_ws_gateway.py; exit 0'
    sleep 2
    SUDO docker exec -d autoware bash -lc "export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/udp.xml; export LANELET_OSM=/root/autoware_map/${2:-$TOWN_DEFAULT}/lanelet2_map.osm; export CARLA_SPAWN='$SPAWN_DEFAULT'; export RVIZ_DISPLAY=:1; source /opt/autoware/setup.bash; python3 -u /root/ros_ws_gateway.py --ros-args -p use_sim_time:=true > /tmp/gw.log 2>&1"
    command -v adb >/dev/null && adb reverse tcp:8765 tcp:8765 >/dev/null 2>&1
    for i in $(seq 1 30); do SUDO docker exec autoware bash -lc "ss -tlnp 2>/dev/null | grep -q 8765" && { echo "gateway up (ws://<host>:8765/ws)"; break; }; sleep 2; done
    ;;
  app)
    # ROii Command = primary tablet app (Tesla dashboard + 8-town map selector)
    cd /home/kim/roii_command
    export PATH="$PATH:/home/kim/flutter/bin"
    flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk
    adb reverse tcp:8765 tcp:8765 && adb shell monkey -p com.keti.roii.command 1 >/dev/null 2>&1
    echo "ROii Command 설치+USB 연결+실행 완료"
    ;;
  kill)
    SUDO pkill -9 -f CarlaUE4-Linux-Shipping
    SUDO docker stop autoware >/dev/null
    echo "정리 완료 — CARLA 종료, 컨테이너 정지 (전기 절약). 다시 켜기: ./run.sh"
    ;;
  multimode) MULTIMODE=1 exec bash "$REPO/scripts/run_localization_demo.sh" "${2:-$TOWN_DEFAULT}" ;;
  osm)       NIRO=1 exec bash "$REPO/scripts/run_osm_demo.sh" "${2:-soongsil}" ;;
  niro)      # Niro 실차 구성: 단일 Ouster OS2-128 + RTK-GNSS + IMU, 이중측위(LiDAR/GNSS)
             NIRO=1 MULTIMODE=1 exec bash "$REPO/scripts/run_localization_demo.sh" "${2:-$TOWN_DEFAULT}" ;;
  niro-fault)  # 라이다 결함 주입 N초 (태블릿 FAULT 버튼과 동일)
             DEX "ros2 topic pub --once /multimode/inject std_msgs/msg/String '{data: lidar_fail}'"; echo "LiDAR 결함 주입 -> GNSS 폴백" ;;
  niro-clear)  DEX "ros2 topic pub --once /multimode/inject std_msgs/msg/String '{data: clear}'"; echo "결함 해제 -> 정상 이중측위" ;;
  roii)      exec bash "$REPO/scripts/run_roii_lidar_${2:-low}.sh" "${3:-$TOWN_DEFAULT}" ;;
  mapdaemon) exec bash "$REPO/scripts/map_switch_daemon.sh" ;;
  Town*)     SUDO docker start autoware >/dev/null 2>&1; exec bash "$REPO/scripts/run_localization_demo.sh" "$CMD" ;;
  *)         grep -E "^#   ./run.sh" "$0" | sed 's/^#   //'; exit 1 ;;
esac
