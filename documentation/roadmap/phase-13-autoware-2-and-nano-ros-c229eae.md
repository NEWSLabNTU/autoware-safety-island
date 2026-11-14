# Phase 13 - Autoware 2.0.0 upstream, nano-ros main c229eae090

Status: done (2026-11-13). A and B done, CI green. C1-C7 done, on
nano-ros pin 8a71f9b34e (four nano-ros PRs, see C results); C3 closed
with the bridged demo driving to its goal on Autoware 2.0.0. Carried
over: C5 and C7 are not measured on hardware, and C8 waits for the
user's DCO sign-off. The
`nano-ros` branch is rebased onto upstream `main` ec3f08a ("feat!: target
Autoware 2.0.0", #75). B pinned nano-ros main c229eae090 (main 0a4cfcc063
plus nano-ros PRs 3640 and 3642, which this phase filed); C moved it to
8a71f9b34e.

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

### C results (2026-11-13)

nano-ros PRs filed by this part, all on main and in the pin 8a71f9b34e (main, 84 commits past c229eae090):
3703 (arena), 3704 (owned-entry census), 3705 (Zephyr boot priority
read-back), 3709 (a board package also on `NROS_EXTRA_BOARD_PATH` is one
board).

| # | outcome |
|---|---|
| C1 | Done, in nano-ros (PR 3703). The arena model priced every subscription at the image-wide receive buffer whenever a descriptor row stated no QoS depth, although that fallback used the budgeted depth (`NROS_PUBSUB_QOS_DEPTH=1`) anyway. A depth-less row is now priced at the budgeted depth and its own type's bound (the 27,100 B trajectory, 880 B odometry, ...). Derived arena on every lane: 94,840 B (was 353,344 on POSIX and 1,385,536 on AN536 / S32Z2), against 90,552 B claimed at first spin on AN536; the "arena larger than needed" advisory is gone. S32Z2 FreeRTOS: `.bss` 2,342,116 B, 1,305,004 B of the 3,584 KiB RAM region free (13,972 before, 1,250,908 in phase 12) |
| C2 | Done. `src/freertos_posix_entry/si_dds_interface.cpp` defines `nros_board_network_wait()`, which the FreeRTOS runner calls just before it opens the session, and turns `SI_DDS_INTERFACE` (name, IPv4 or `auto`) into a `CYCLONEDDS_URI` fragment; every boot logs a "Network interface" line. A name that is no interface makes the session refuse to open, so the selector is applied, not only logged. The fragment adds to an operator's own `CYCLONEDDS_URI` (Cyclone's interface list), so naming the same interface in both fails; the binary warns. The POSIX CI lane checks the default line, the IP, name and `auto` forms and the refusal. `release.yml`: the FreeRTOS build job gets the nano-ros steps of `build-ci.yml` and ships `libddsc.so.0` (the entry links Cyclone from the nano-ros SDK store) beside `actuation_freertos`; the smoke job sets `LD_LIBRARY_PATH`. Run locally the way the smoke job runs: ubuntu:22.04 and 24.04 x (default, `lo`, `auto`) all start, log "Network interface", reach "Actuation Safety Island is Live" and wait for data. The release workflow itself only runs on a tag and was not run |
| C3 | Done (see "C3: the demo on Autoware 2.0.0" below). `demo/component_state_monitor_topics.yaml` is now 2.0.0's own list with the two control-command checks relaxed to warn 2 Hz / error 0.5 Hz, mounted again at `autoware_launch/config/system/component_state_monitor/topics.yaml` (2.0.0 lists `/planning/trajectory` and dropped the `/initialpose3d` check); `check-demo-diag-graph.py` passes against the 2.0.0 image. A first pass did not run the demo scripts (their bridge and visualizer images need a `docker build`); instead the 2.0.0 planning simulator ran with the compose service's mounts and command (`docker run`, domain 87 over loopback) beside the POSIX island on the same domain, no bridge, seeded as `run-posix-demo.sh` seeds. Measured: the planner publishes 140-point trajectories at 10 Hz (`planning_validator`, max 2.22 m/s); the island publishes control_cmd at 29.8-30.4 Hz; `change_to_autonomous` succeeds. Two faults found: (1) the island's MPC never received a reference trajectory ("input trajectory is empty" every cycle, then an emergency stop): phase 7 W10 removed `setTrajectory()` from `run()` because `isReady()` called it, and upstream #48 then removed it from `isReady()`; fixed in cc35af9, after which the MPC tracks (steering 0.539 rad). (2) The runbook's ego seed is 5.33 m from the 2.0.0 planner's lane, beyond the MPC's admissible position error, so the first cycle stops; re-seeded on the planned lane (0.17 m) the MPC runs. The "ego does not move after engage" reported here was a misreading: the check sampled 30 s after engage, after the ego had already driven to the goal (see below) |
| C4 | Done, in nano-ros (PR 3704). `freertos_posix_entry` matches the `<image>_entry` spelling of an RFC-0071 owned entry, so the census tried to configure that launch-only entry standalone for the host. The owned-entry census now applies only when the bringup declares no `[[component]]`; this image is sized by its model like the others, and `nros configure` no longer prints the failed host build |
| C5 | Done: `spin_period` 5 ms -> 30 ms, the task's only release (the control timer, `ctrl_period` 0.03). The period is the idle park timeout and the bound of `release-jitter-runtime`; arrivals break the park and timer dues end it. Measured on AN536 / QEMU: at 5 ms, `measured=6000-7000 declared=5000` on every boot; left unset, nano-ros derives 1 ms here (no contract states the timer period) and reports `measured=9000 declared=1000`; at 30 ms, no violation in the 90 s smoke, nor on POSIX or the FVP controller boot. Not measured on hardware |
| C6 | Done, in nano-ros (PR 3705). The Zephyr boot thread adopted the boot sched task's priority with `k_thread_priority_set()`, which Zephyr 3.7 does not trace, and printed nothing. Both Zephyr runners now read it back (`k_thread_priority_get()`) and print the FreeRTOS / NuttX marker. FVP: ``nros: sched task priority set sched_task=`control` prio=9``, and the FVP CI lane requires it. The "NOT checked against the transport" line stays: Cyclone on Zephyr creates no transport task at an explicit priority, so there is no band to compare with |
| C7 | Done. The target had not been built since the nano-ros move and did not configure: it used the FVP's nano-ros board (SMP, SMSC NIC overlay, AArch64 Rust triple), hal_nxp / cmsis were at upstream's pins for its older zephyr ("SoC s32z270 not supported"), the 8 MiB heap exceeds rlsf's 4 MiB pool on a 32-bit core, and the image did not fit sram0 (1 MiB). Now: this workspace's own board package `src/s32z270_zephyr_board` (`[image.s32z]`, Rust triple `armv7r-none-eabihf`), cmsis / hal_nxp at Zephyr v3.7.0's pins, a 2 MiB heap (3.4x the AN536 peak of 618,880 B) and the existing 7 MiB SRAM2 overlay. Links: RAM 6,644,740 B of 7 MB (90.5 %) at pin 8a71f9b34e. Not run (no emulator models the SoC) |
| C8 | No upstream PR opened (the DCO sign-off is the user's). Draft below |

CI on `nano-ros` 50f6852 (pin 8a71f9b34e): run 43364619105, Zephyr FVP,
FreeRTOS AN536 and FreeRTOS POSIX all green
(https://github.com/NEWSLabNTU/autoware-safety-island/actions/runs/43364619105).

### C3: the demo on Autoware 2.0.0

The open item of the first C3 pass, "after engage the ego does not move",
was not a stall. That check slept 30 s after engage and then sampled
once. Its own output shows the ego before engage at (3716.83, 73723.02)
and after at (3715.32, 73753.57), 1.2 m from the goal: the ego had driven
about 30 m and stopped at the goal. Velocity 0 and acceleration
-3.4 m/s^2 are the PID's STOPPED output at the goal, and the converged
steering is the parked steering. The per-second traces of the drives
below end in the same state (v 0, a -3.4 m/s^2) once the ego stops at
the goal.

The full demo, `scripts/run-posix-demo.sh --drive` (compose stack:
Autoware `universe-humble-2.0.0` planning simulator, domain bridge,
visualizer; the POSIX island on domain 2; `SAFETY_ISLAND_DDS_INTERFACE=lo`),
run from a fresh stack:

| measurement | value |
|---|---|
| mission | spawn (3714.43, 73753.16) on lanelet 9428, derived from the map; route 30 m along the lane to (3738.00, 73750.92), accepted by `set_route_points` |
| engage | `change_to_autonomous` succeeds on the first call |
| island state changes | STOPPED -> DRIVE at engage, DRIVE -> STOPPING 1.3 s before the stop, STOPPING -> STOPPED |
| drive | 29.4 m in 16-17 s, peak 2.36 m/s (planner limit 2.22 m/s), peak steering command -0.46 rad in the curve |
| goal | stops 0.04-0.06 m from the goal; route state ARRIVED (3); Autoware drops to STOP mode by itself |
| control_cmd, domain 1 (bridged) | 28.7-29.9 Hz over 25 s windows, island the only publisher; the gate output follows it 1:1 while autonomous |
| domain 2 (island side) | trajectory 10.0 Hz, steering status 40.0 Hz, control_cmd 28.9 Hz |
| repeat | three drives (two scripted, one by hand on the same poses), goal within 0.06 m each time; the two traced drove 29.4 and 29.5 m |
| visualizer | noVNC answers on :6080, rviz2 is up and on domain 1 |

What changed for it:

- fbe210e: the PID logged every state change as `<invalid utf-8>`
  (a `std::string` passed through `log_info`'s varargs; upstream has the
  same line). Now `controller state changed: STOPPED -> DRIVE`.
- f4e9433: the visualizer image exited at start on the 2.0.0 base
  (Ubuntu 22.04 moved `vncpasswd` to `tigervnc-tools`).
- 7940164: `run-posix-demo.sh --drive`. The driving mission of
  `run-tap-demo.sh --drive` moves to `scripts/demo-drive-mission.sh`,
  shared by both. Its map deriver read `/root/autoware_map`, but the
  2.0.0 compose file mounts `/autoware_map`, so it had fallen back to the
  hand-probed poses; fixed. The default (non-drive) seed is 5.3 m off the
  lane 2.0.0 plans and heads 102 deg against the lane's 92 deg, so it only
  exercises the island's emergency stop ("too large position error"); kept
  as the rate check, documented, and `--drive` is the driving demo.
- The run-tap-demo.sh FVP / AN536 lanes need tap0 / tap1 (root), so
  `--drive` was not run there; the shared mission is the code measured
  above.

### C8 draft: upstream-ready patch (phase 12 C item 3)

Phase 12 C ranks the contributions; nothing about them changed in this
phase except that item 3 is ready. Upstream's `Controller::processData()`
still routes all five "Waiting for ... data" lines through one lambda,
and `log_info_throttle` keys on `(__FILE__, __LINE__)`, so the five share
one throttle slot: the first missing input is logged and the other four
never are. This branch fixed it as part of the controller port. The
patch below applies to upstream `main` ec3f08a as is; it needs the
user's `Signed-off-by` (DCO) before it can be filed, with the subject
`fix(controller): give each missing input its own throttle slot`.

```diff
--- a/actuation_module/src/autoware/autoware_trajectory_follower_node/src/controller_node.cpp
+++ b/actuation_module/src/autoware/autoware_trajectory_follower_node/src/controller_node.cpp
@@ -587,28 +587,27 @@
 {
   bool is_ready = true;
 
-  const auto & logData = [this](const std::string & data_type) {
-    log_info_throttle(("Waiting for " + data_type + " data").c_str());
-  };
-
+  // Each wait has its own log_info_throttle call site. The throttle keys on
+  // (__FILE__, __LINE__), so one shared lambda gave all five a single slot:
+  // the first missing input was logged and the other four never were.
   if (!has_accel_) {
-    logData("acceleration");
+    log_info_throttle("Waiting for acceleration data");
     is_ready = false;
   }
   if (!has_steering_) {
-    logData("steering");
+    log_info_throttle("Waiting for steering data");
     is_ready = false;
   }
   if (!has_trajectory_) {
-    logData("trajectory");
+    log_info_throttle("Waiting for trajectory data");
     is_ready = false;
   }
   if (!has_odometry_) {
-    logData("odometry");
+    log_info_throttle("Waiting for odometry data");
     is_ready = false;
   }
   if (!has_operation_mode_) {
-    logData("operation mode");
+    log_info_throttle("Waiting for operation mode data");
     is_ready = false;
   }
 
```

The other phase-13 changes are nano-ros specific (C1, C2, C4-C7) or demo
configuration for the nano-ros island (C3), and have no upstream form.
