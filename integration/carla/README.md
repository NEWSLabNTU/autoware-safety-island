# The Safety Island on CARLA

`run-carla.sh` drives swb's `drive_to_goal` scenario (CARLA 0.9.16, Town01,
swb's `tesla_model3`, Autoware 2.0.0) with this repository's island as the
ego's only trajectory follower. It reuses the L4 integration runner
(L4SafetyIsland_Implementation, `ci/runner`) and adds only this directory:

```bash
L4SI_DIR=<L4 checkout> integration/carla/run-carla.sh
```

Exit code: the runner's (0 passed, 1 failed, 2 error, 3 refused). Logs and the
run's artifacts land in `log/carla/`.

## What runs

| Piece | Where |
|---|---|
| Autoware 2.0.0 + swb, the runner's `local` service | `l4si-ci-stack` image, `compose.island.yaml` override |
| CARLA, GPU | the runner's `carla` service, compose project `asi-carla` |
| ego: `trajectory_follower_mode: none` | `demo/launch/safety_island_preset.yaml`, mounted as the `safety_island` preset |
| diagnostic graph without `controller_node_exe`'s `control_state` | `autoware-sim-safety-island.yaml` |
| the island | `build.sh --platform freertos-posix-carla` (wheel base 3.005 m, PID pitch +-0.2 rad), staged in `build/carla-island` |
| domain_bridge, ego domain (swb seat 0, 2) <-> island domain (`ASI_ISLAND_DOMAIN`, 20) | `island-run.sh`, the demo's `bridge/bridge-config.yaml` and its 1400 B cap |
| the record the checks read | `island-monitor.py` (per second) and a rosbag2 recording (`island-bag/`) |

The island runs at real-time priority (`SCHED_FIFO`, `ASI_ISLAND_RT_PRIO`,
default 10; 0 leaves it at the default policy). The runner drops to an
unprivileged user, so `run-carla.sh` raises every island thread with
`docker exec -u root ... chrt`, using the container's `SYS_NICE` and no other
capability. `island-rt.log` lists each thread's policy.

## Harness step: operator re-enable before the drive

CARLA runs synchronously and swb pauses the world from the stack's start until
the scenario runs. The island's feedback watchdogs run on its own wall clock
(steering report 0.5 s, odometry 0.4 s), so they see the paused sources stop
and latch `SI_STOP` before any driving. A latch clears only on an operator
re-enable (`/control/safety_island/reenable`, `std_msgs/Bool`) once every
source is fresh again.

The harness is that operator: while the ego is not yet in AUTONOMOUS mode,
`island-monitor.py` sends the re-enable once a second on the island's domain.
From the first AUTONOMOUS second on it sends nothing, so a latch while driving
stays latched and fails the run. When swb ends the scenario it pauses the world
again, and the island latches on the stopped odometry; `island-check.sh` lists
that latch as "after the drive".

## Pass checks

swb's verdict (reach the goal within 5 m in 180 s), then `island-check.sh`
(the runner's `L4SI_ISLAND_CHECK`):

1. the island entered DRIVE;
2. no `SI_STOP latched` while driving (from the first AUTONOMOUS second to
   the last second with fresh odometry);
3. its control_cmd on the ego's domain at >= `ASI_MIN_RATE_HZ` (25) on
   average over the seconds the ego drove (> 0.5 m/s); counted from the
   rosbag2 recording when present, else from the monitor; both are printed,
   with the island-side count before the bridge;
4. no `controller_node_exe` on the ego's graph;
5. `/control/command/control_cmd` non-zero while driving.
