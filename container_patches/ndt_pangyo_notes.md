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
