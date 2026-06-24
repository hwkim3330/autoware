# rviz 프로파일 (모니터 뷰)

| 파일 | 용도 | 표시 |
|---|---|---|
| `niro_realmap.rviz` (= container_patches/roii_clean.rviz) | 실제맵 planning_sim (판교/K-City) | lanelet 벡터맵 + pointcloud_map(고도색) + 가상 LiDAR 스캔 + 경로 + 궤적 + 차량 |
| `../container_patches/autoware_no_camera.rviz` | CARLA 일반 (카메라 없음) | NDT 측위 + 라이브 라이다 + 궤적 |
| `../container_patches/roii_lidar_fault.rviz` | CARLA 4-LiDAR 결함 시연 | per-LiDAR 클라우드 + 결함 상태 |

실제맵: `./run.sh real /root/autoware_map/<site>` → niro_realmap 뷰
CARLA: `./run.sh niro|roii` → CARLA 뷰
