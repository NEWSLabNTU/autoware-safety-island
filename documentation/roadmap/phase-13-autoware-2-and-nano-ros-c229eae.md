# Phase 13 - Autoware 2.0.0 upstream, nano-ros main c229eae090

Status: A and B done, CI green (2026-11-13). The `nano-ros` branch is rebased onto
upstream `main` ec3f08a ("feat!: target Autoware 2.0.0", #75) and pins
nano-ros main c229eae090 (main 0a4cfcc063 plus nano-ros PRs 3640 and
3642, which this phase filed). C lists what is left.

Inputs:

- upstream = autowarefoundation/autoware-safety-island `main` ec3f08a, 3
  commits past c92271b: 5add988 (release v0.2.0 prep, #74), 1e4f504 (vcan
  load order, #76), ec3f08a (target Autoware 2.0.0, #75).
- fork `nano-ros` before this phase: f3906d5, archived as tag
  `archive/nano-ros-2026-11-12`.
- nano-ros: previous pin 4fcc75d413 (2026-10-31); new pin main c229eae090
  (2026-11-13), 1393 commits later. The migration was done against main
  0a4cfcc063; c229eae090 is that plus 22 commits, among them the two fixes
  below.

## A. Rebase onto upstream main ec3f08a

A plain `git rebase` of the 34 commits. Four commits conflicted; the rest
replayed clean.

| commit | file | upstream change | resolution |
|---|---|---|---|
| controller | `include/common/dds/config.hpp` | `SI_DDS_INTERFACE` runtime override of the CycloneDDS interface (POSIX) | kept deleted: the nano-ros port has no `common/dds` layer. The override is not ported (C2). |
| controller | `controller_node.cpp` | trajectory topic `/planning/scenario_planning/trajectory` -> `/planning/trajectory` | kept the nros subscription code; the topic lives in `controller_pkg/node_identity.hpp` (`SUB_TRAJECTORY`), renamed there |
| test | `test/dds_pub.cpp`, `test/dds_sub.cpp` | same topic rename | kept the nros test bodies, renamed the topic |
| ci | `.github/workflows/release.yml` | pinned devcontainer image, bridge-contract check, POSIX smoke job | took upstream's file and kept our two edits: `options: --user 0:0 --entrypoint=` and only the `zephyr` submodule. Dropped our Zephyr workspace cache step (upstream removed it) |
| ci | `.github/workflows/build-ci.yml` | vcan load order (#76) | our side: the nano-ros branch does not run the vcan / FVP-TAP jobs |
| ci | `.github/scripts/run-freertos-posix-ci.sh` | `SI_DDS_INTERFACE` smoke markers | our side (no CycloneDDS interface log on nros); kept upstream's new Phase 6 bridge-contract check |
| demo | `demo/docker-compose.yaml` | Autoware `universe-humble-2.0.0` image, `trajectory_follower_mode: none` preset, diagnostic graph override, `control.launch.xml` override removed | took upstream; our `component_state_monitor_topics.yaml` mount dropped (C3) |
| demo | `demo/cyclonedds-s32z2.xml` | MaxMessageSize moved to `bridge/cyclonedds-domain2.xml` | our demo commit had deleted the file; kept upstream's version, since its docs still point at it |

Folded into the commits that introduced them (same topic rename):
`controller_bringup/launch/system.launch.xml` remap, and the demo scripts
`scripts/an536-{observer,rx-counters,sweep-pub}.py`,
`scripts/run-{posix,tap}-demo.sh`.

Messages: upstream's 2.0.0 move changed no `.msg`/`.idl`, only the
trajectory topic, the demo stack and the release flow. The rosbag test
replays the old topic under the new name (upstream `play_rosbag.sh`).

## B. nano-ros 4fcc75d413 -> c229eae090

What the new nano-ros refused, and what changed in this repo for it:

| # | refusal at the new pin | change |
|---|---|---|
| 1 | `[[component]] group_tiers` is retired (rlm v0.3.11, phase-536): "write `group_tasks`" | `play_launch migrate` on `controller_bringup/system.toml`: `group_tiers` -> `group_tasks`, `[tiers.control*]` -> `[tasks.control*]`. Comments in the controller, CMake and CI renamed to match |
| 2 | `unknown field spin_period_us` (rlm v0.3.0: durations carry a unit) | `spin_period = "5000us"` |
| 3 | `nros configure`: `<depend>` name `nano_ros` resolves to nothing | `controller_pkg/package.xml`: `<depend>nros</depend>` |
| 4 | the same check read `rows here.   -->` out of a package.xml COMMENT | nano-ros bug, fixed upstream: PR 3640 (742c700cf7) |
| 5 | `invalid source metadata JSON ... expected value`: the metadata sidecar wrote `"default":inf` for `source_timeout_opmode_s` (default `std::numeric_limits<double>::infinity()`) | nano-ros bug, fixed upstream: PR 3642 (c229eae090; a non-finite default is written as a JSON string) |
| 6 | arena oracle (phase-412): stated `NROS_EXECUTOR_ARENA_SIZE=131072` is below the model, 1,271,464 B at the ROS default depth 10 | `NROS_PUBSUB_QOS_DEPTH=1` on every lane (all seven subscriptions are KEEP_LAST(1); the sidecar records depth 1). The model is then 353,344 B on freertos-posix, still above 131072, so the arena is no longer stated and the build derives it |
| 7 | Zephyr: "zephyr-lang-rust ... is missing nano-ros patch hunks" (issues 2185, 2407) | FVP CI runs `modules/nros/scripts/zephyr/patches/3.7.sh` on the west workspace before building (step (b) of `nros setup board`, which bootstrap-asi.sh already runs locally) |
| 8 | Zephyr promise check: "entity inventory was composed after this configure's readers ran, and no `nros configure` seeded them" | build.sh passes `-DNROS_IMAGE_SYSTEM_DIR=actuation_module/src/controller_bringup -DNROS_IMAGE=fvp` for the controller image (RFC-0120 D5 hook). Test images stay guests and pass neither, otherwise the promise check refuses their missing sizing descriptor |
| 9 | `nros sync` is a deprecated alias of `nros configure` | build.sh and the CI scripts call `nros configure` / `nros configure --check` |

Not needed here, though the island migration needed them: the bringup
already held the only `system.toml` (RFC-0121 D2), and there were no
`<entry>__<id>` configure stamps to remove.

### Results

Local runs on the rebased branch (2026-11-13), at 0a4cfcc063 with the two
fixes applied (FreeRTOS POSIX re-run at c229eae090), the CI scripts
unchanged except where B says:

| lane | result |
|---|---|
| FreeRTOS POSIX (`run-freertos-posix-ci.sh`) | build, `nros configure --check`, runtime smoke, host unit tests, CAN decoder/bridge checks, bridge contract, CAN UDP tunnel: pass |
| Zephyr FVP, controller | build; boots to "Actuation Safety Island is Live" |
| Zephyr FVP, unit / DDS loopback / CAN loopback | build and pass on the model |
| Zephyr FVP, stats | pass, stack headroom under 85 % |
| Zephyr FVP, TAP | builds, `CONFIG_NROS_DOMAIN_ID=2` |
| FreeRTOS AN536 (`run-freertos-an536-ci.sh`) | build, `nros configure --check`, QEMU smoke: pass. The sched-task marker is now "sched task priority set sched_task=`control`" (was "tier priority set tier=`control`") |
| FreeRTOS S32Z2 | links |

Arena, derived now (stated before): freertos-posix 353,344 B, of which
91,512 B is claimed at first spin; AN536 1,385,536 B, 90,552 B claimed
(64 KiB rx). On S32Z2 that leaves 13,972 B of the 3,584 KiB RAM region
free (`.bss` 3,641,004 B), against 1,250,908 B free in phase 12.

CI on `nano-ros` 674b939 (pin c229eae090): run 43269692167, Zephyr FVP,
FreeRTOS AN536 and FreeRTOS POSIX all green
(https://github.com/NEWSLabNTU/autoware-safety-island/actions/runs/43269692167).

## C. Remaining migration

| # | item | effort | risk |
|---|---|---|---|
| C1 | Arena RAM on the R52 lanes. The derived arena is 15x the measured claim, and S32Z2 now has 14 KB of RAM left. The runtime advises `NROS_EXECUTOR_ARENA_SIZE=91136`, but the build-time oracle refuses any stated size below its model. Fix it upstream (the model prices each subscription at `depth x rx_buf`, which the claim shows is not what the executor allocates), or state the subscription bounds so the model shrinks: declare the real interface packages in `controller_pkg/package.xml` so message bounds get seeded ("message bounds not seeded: no node package resolves an interface package"), or add a `*.contract.yaml` with `qos.depth`. Must land before hardware runs on S32Z2 | M | high: a hardware build that grows any static buffer stops linking |
| C2 | `SI_DDS_INTERFACE` (upstream #75): a runtime override of the CycloneDDS network interface for the POSIX binary. The nano-ros POSIX lane takes its interface from nano-ros's Cyclone config; there is no override and no "Network interface" log line. Upstream's `release.yml` smoke job greps for that line, so a tag built from this branch would fail it | S-M | low: the release flow does not run on this branch |
| C3 | Demo stack on Autoware 2.0.0. `demo/docker-compose.yaml` follows upstream (2.0.0 image, `trajectory_follower_mode: none`, diagnostic graph override). Our `demo/component_state_monitor_topics.yaml` (relaxed control-command rate checks for the slow FVP island) is not mounted: it was written for the `universe-20250207` layout and still lists `/planning/scenario_planning/trajectory`. Re-check against the 2.0.0 image, then mount it at the `/opt/autoware/autoware_launch/share/...` path or drop it. The run-tap/posix demo scripts were not run against 2.0.0 | M | medium: demo only, not CI |
| C4 | Census of the FreeRTOS POSIX entry. `nros configure` cannot take the host census of `src/freertos_posix_entry` (its CMakeLists calls `nano_ros_add_executable`, which a standalone host census configure does not define), so that image's counts come from the controller's sidecar. It is a warning; `[[component]] entities = [...]` or a census-able entry silences it | S | low |
| C5 | Release-jitter contract warning on AN536: "contract violation: release-jitter-runtime spin measured=7000 declared=5000". The 5 ms `spin_period` of `[tasks.control]` is not met under QEMU. Measure on hardware before changing the declaration | S | low |
| C6 | Zephyr FVP: the boot log says "sched task priorities NOT checked against the transport: no task in this image was created at an explicit priority". Confirm `[tasks.control.zephyr] priority = 9` still reaches `main` (phase 8 found that Zephyr 3.7 does not trace `k_thread_priority_set`) | S | medium: an unapplied priority is silent |
| C7 | The S32Z Zephyr target (release only) reuses `[image.fvp]`. It was not built here | S | low |
| C8 | Remaining items from phase 12 C (contribute back) are unchanged | - | - |
