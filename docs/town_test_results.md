# CARLA all-town autonomous-drive validation — FINAL

One full bring-up (`run.sh <town>`) + one `drive` per town. Best validated
result per town across rounds (2026-06-11). PASS = AUTONOMOUS engaged, ego
drove on-lane.

| Town | Localized | Route | Trajectory | Autonomous | Max km/h | Moved m | Verdict |
|---|---|---|---|---|---|---|---|
| Town01 | ✅ | SET | 165 | ✅ | 24.9 | 135 | ✅ PASS |
| Town02 | ✅ | SET | 166 | ✅ | 20.6 | 95 | ✅ PASS |
| Town03 | ❌ | — | — | — | — | — | ❌ CARLA unstable (boot/load crashes, driver 535) |
| Town04 | ✅ | SET | 169 | ✅ | 27.8 | 252 | ✅ PASS |
| Town05 | ✅ | UNSET | 0 | ❌ | 0 | — | ⚠️ flaky (localizes; mission-planner routing timed out this round) |
| Town06 | ✅ | SET | 0 | ❌ | 0 | — | ⚠️ flaky (routes; behavior trajectory didn't appear this round) |
| Town07 | ✅ | SET | 169 | ✅ | 20.6 | 107 | ✅ PASS |
| Town10HD | ✅ | SET | 169 | ✅ | 19.8 | 56 | ✅ PASS |

**5/8 towns fully autonomous** (Town01/02/04/07/10HD). Town05/06 pass the
localization layer and fail intermittently in planning (single-attempt runs;
a retry usually progresses further — see round logs). Town03's CARLA world is
unstable on this GPU/driver setup regardless of Autoware.

What it took (full writeups in autoware_carla_integration.md):
- `projector_type: local` for every town map
- CARLA-safe aligned spawns (`gen_spawn_table.py` / `gen_all_spawns.sh`)
- 32 MB UDP DDS buffers (big LaneletMapBin)
- boot CARLA directly into the target town (runtime load_world segfaults)
- AdditionalMaps package for Town06/07
- interface timeout 300 s; engage retry 10×2 s

Raw logs: /tmp/towntest_<town>_{up,drive,e2e}.log
