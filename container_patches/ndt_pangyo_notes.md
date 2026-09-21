# NDT parameters for the synthetic Pangyo map

Applied by `scripts/run_pangyo_awsim.sh` step [0] to
`/opt/autoware/share/autoware_launch/config/localization/ndt_scan_matcher/ndt_scan_matcher.param.yaml`
inside the container.

    max_iterations                                        30 -> 50
    converged_param_nearest_voxel_transformation_likelihood  UNCHANGED at 2.0

## Why

Measured 2026-07-28. On the shipped Shinjuku map Autoware drives with these
defaults. On pangyo_regen the vehicle accelerates to 11.45 m/s, covers 236 m and
then brakes hard and rolls back, always at the same place. The diagnostic at the
stop:

    ndt_scan_matcher: The number of iterations has reached its upper limit. 30/30
                      Score is below the threshold. Score: 1.6767, Threshold: 2
                      skipping_publish_num exceed limit (485 times)
    ekf_localizer:    [ERROR] pose is not updated
                      cov_ellipse_lateral_direction is large
    localization_error_monitor: ellipse size is too large

So NDT does not diverge -- it converges to a 1.68 score against a 2.0 gate, then
declines to publish at all. Everything downstream follows from that missing pose:
EKF stops updating, the covariance ellipse grows, localization is declared
unreliable, the trajectory collapses to a 30 m stop and the controller brakes.

The map is synthetic -- terrain grid plus building footprints extruded from VWorld
LT_C_SPBD -- so it has fewer and cleaner features than a real survey scan and
scores lower by construction. Loosening the gate is the honest adjustment for that;
the alternative is denser real features in the point cloud, which is generator work
(see PLAN_pangyo_awsim.md's generator-gaps section).

## Loosening the gate was tried and REVERTED

Dropping the likelihood gate 2.0 -> 1.0 to get past the 1.6767 score made things
strictly worse. With the looser gate NDT accepted a poor-but-converged solution
and locked the heading about 63 deg off the lane on all six seed attempts --
172.9, -162.8, 176.2, 173.7, 173.5, 172.2 deg against a lane bearing of 109.7 --
so the run never reached routing at all, let alone driving. At 2.0 the same seed
lands within a degree on the first or second try and the vehicle drives 236 m.

So the gate was not the obstacle; it was rejecting exactly the bad matches that
the map's weak features invite. Only max_iterations is raised. The real fix is
denser, more distinctive features in the point cloud -- generator work, see the
generator-gaps section of PLAN_pangyo_awsim.md.

## 2026-09-21 측정: 희소성이 맞고, "236 m 국소 결함"은 틀렸다

위 문서는 원인을 "합성 지도라 특징이 적다"로 추정했다. 실측으로 확정했다.

NDT 가 실제로 쓰는 단위 — 2.0 m 복셀, PCL VoxelGridCovariance 의 최소 6점 —
으로 전체 지도를 세면:

    pangyo_regen   복셀 206,081  평균  4.87점  중앙값  5점   6점 이상 46.2%
    shinjuku       복셀 127,437  평균 36.42점  중앙값 33점   6점 이상 84.0%

센서 반경 60 m 안, 주행 경로 위에서 세면 차이가 더 크다:

    거리      점      복셀    쓸 수 있는 복셀
    판교   0 m   12,789   2,748   1,148 (41.8%)
    판교  60 m    9,241   2,161     677 (31.3%)
    판교 120 m   13,137   2,722   1,024 (37.6%)
    판교 180 m   11,697   2,656     941 (35.4%)
    판교 236 m   13,819   3,093   1,160 (37.5%)   <- 멈추는 곳
    판교 300 m    7,979   2,164     516 (23.8%)
    신주쿠 중앙  269,354   7,164   5,918 (82.6%)

한 스캔 범위 안에서 **점이 20배, 쓸 수 있는 복셀이 5배 적다.**

중요한 정정: **236 m 는 특이점이 아니다**(37.5%, 60 m·300 m 보다 오히려 낫다).
위 문서의 "always at the same place" 라는 관찰이 국소 결함을 암시했지만, 희소성은
전 구간 균일하다. 점수가 어디서나 문턱 바로 언저리에 있다가 누적 오차가 쌓여
그 지점에서 처음 밑으로 떨어지는 것이지, 그 자리에 특징 구멍이 있는 게 아니다.

### 생성기의 세 밀도가 전부 6점을 못 넘긴다 (gen_real_map.py)

    지면 격자   4.0 m x 4.0 m        -> 2 m 복셀당 0.25점
    도로 표면   1.0 m x 1.0 m, 폭 6 m -> 2 m 복셀당 4점
    건물 벽     0.8 m x 0.7 m        -> 2 m 복셀당 7점  (유일하게 통과)

이것이 "쓸 수 있는 복셀"이 건물 있는 곳에만 몰리는 이유다. 신주쿠 수준
(~4,700 k점/km2)에 맞추려면 지면 0.7 m, 도로 0.4 m, 벽 0.35/0.3 m 정도 —
약 8.5M 점, 102 MB.

### 반박된 가설: 격자 규칙성

합성 지도의 규칙적 격자가 NDT 에 가짜 최소점을 준다고 의심했으나 아니다.
4 m 주기 격자선 +-1 cm 위의 점 비율이 판교 0.5%, 신주쿠 0.6% 로 같다
(둘 다 무작위 기댓값). 좌표 변환과 지형 드레이핑이 이미 규칙성을 깼다.

### 재생성 없이 조밀화하는 길 (네트워크·lanelet 손대지 않음)

environment.obj 가 같은 표면을 메시로 갖고 있어 임의 밀도로 다시 샘플링할 수 있다.
프레임은 추측하지 말 것 — 실측으로 확정했다:

    enu = (obj_z, -obj_x, obj_y) + (32278.5, 41244.6, 0)

건물 정점 1,650개의 최근접 PCD 점까지 거리 중앙값 0.300 m, 90% 0.600 m
(= 기존 점 간격의 절반. 다른 세 후보 매핑은 중앙값 10~19 m 로 명백히 틀림).

부수 발견: **PCD 에 지붕 점이 없다.** 생성기는 벽 모서리만 수직으로 샘플링한다
(`for z in arange(0.3, h, 0.7)`). 그런데 AWSIM 의 시뮬 라이다는 지붕이 있는
메시에 레이를 쏜다. 지도에 대응 복셀이 없는 스캔 점은 점수에 0을 기여하므로
1.6767 이라는 점수를 직접 끌어내린다. 조밀화할 때 지붕 면도 같이 샘플링할 것.
