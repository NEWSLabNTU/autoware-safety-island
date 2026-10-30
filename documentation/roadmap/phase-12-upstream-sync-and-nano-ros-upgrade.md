# Phase 12 - Upstream sync, nano-ros upgrade, contribute-back plan

Status: IN PROGRESS (2026-10-31). Branch `nano-ros-rebase` carries step A
and step B (nano-ros upgrade, see B. Progress); step C is not started.

Inputs:

- upstream = autowarefoundation/autoware-safety-island `main` c92271b
  (14 commits past the fork base a76b63ff61).
- fork = NEWSLabNTU `nano-ros` 15b079b (238 commits) plus the `main`-only
  commits 5a80fc7, f45d862, 9ae9dde, 9e12a75.
- nano-ros: ASI pin af14492fe (2026-09-10); nano-ros `main` 375fd91f41
  (2026-10-30, +3319 commits); the island repo
  (NEWSLabNTU/simple-autoware-safety-island dec85df) pins 05b7f7d2648f
  (2026-10-27), the newest pin a working consumer has proven.

## A. Rebase onto upstream main (done on `nano-ros-rebase`)

### Approach

A linear rebase of 238 commits was not attempted: the fork deletes the
CycloneDDS layer (`common/dds`, `common/node` DDS shim, `main.cpp`,
`freertos/` and `freertos_s32z2/` CMake trees, the cyclonedds and
freertos-kernel submodules) that 8 of the 14 upstream commits extend, so
nearly every replayed commit would re-conflict on the same files. Instead:

1. `main`-only commits picked onto `nano-ros`: 5a80fc7, f45d862, 9ae9dde,
   9e12a75. Skipped: 0bfc7f5 (same change already on `nano-ros` as
   477cd35) and 9951c4a (pin bump to 1976727d8, superseded by the
   `nano-ros` pin af14492fe, which contains it).
2. One merge of upstream `main` into that state, conflicts resolved once
   (27 files).
3. The resolved tree re-expressed as 8 topical commits on top of upstream
   c92271b. The tree is byte-identical to the merge result. The original
   per-commit history stays on `nano-ros` (untouched).

| commit | topic | files |
|---|---|---|
| build | nano-ros submodule + west pin, bootstrap/ament/knob scripts, drop cyclonedds + freertos-kernel submodules | 23 |
| msgs | nros codegen of the controller's interfaces; supervision msgs | 57 |
| controller | controller on `nros::ComponentNode` + upstream supervision port | 36 |
| platform | generated entries (Zephyr, FreeRTOS POSIX/S32Z2/AN536), build.sh | 61 |
| test | unit tests on nros; standalone host-test project | 6 |
| ci | nano-ros lanes, pin lockstep, an536, host tests | 8 |
| demo | demo runners and probes | 29 |
| docs | design notes, roadmap, reports | 34 |

### Documentation directory

The fork had renamed `documentation/` to `docs/` (a695872). The rebased
branch follows upstream's `documentation/`: every upstream doc change since
the fork landed under `documentation/` and re-conflicted as a rename, and
any doc contribution must target that path anyway. All in-repo references
were rewritten; references to nano-ros's own `docs/roadmap/phase-NNN`
were kept.

### Conflict resolutions

| area | resolution |
|---|---|
| controller_node.{hpp,cpp} | Upstream's file taken as the base (it carries #66 supervised single output, #57 heartbeat staleness, 9eb7952 SI_STOP ramp, #48 fixes), then the nros port re-applied: `nros::ComponentNode` base, static `(msg*, void*)` callbacks turned into typed members whose body is upstream's verbatim, CycloneDDS `_length/_buffer` into `FixedSequence` `size/[]`, value-typed publishers, timer in its own callback group, KEEP_LAST 1, launch-seeded `control_output`, CTF markers, RX counters, one throttle slot per input. `StartupConfig` is read from launch params (`supervision_mode`, `trajectory_source`, `legacy_control_cmd`, `operation_mode_durability`) through `StartupConfig::fromValues`, so the env and param paths share one rule set. The fork's own safe-stop and NaN guard (36d08cf) and trajectory age check are superseded by upstream's HOLD-with-stopped-payload, envelope check and per-source watchdogs. |
| supervision messages | `.msg` twins of upstream's IDL in `autoware_msgs/msg_local/` (visionpilot_msgs DrivingCommand/DrivingReference, safety_island_msgs ApprovedRequest) + std_msgs/Bool from AMENT. `speed_horizon_mps` is bounded `[<=100]` (= `vp_reference::kMaxHorizon`); nano-ros needs a derived receive bound. Upstream's 4 IDL files stay in `msg/`. |
| node identity / launch | 4 new subscription topics + `approved_request` publisher in `node_identity.hpp`, remaps and the 4 startup args in `system.launch.xml`. |
| logger.hpp, node.hpp, unit_test.cpp, build.sh | fork side (nros logger / shim; upstream's edits there are DDS-only). |
| main.cpp, freertos/ + freertos_s32z2/ CMake, common/dds | stay deleted (generated entries replace them). |
| supervision host tests | upstream built them inside the deleted `freertos/CMakeLists.txt`; now `actuation_module/test/host/CMakeLists.txt` (7 tests, no middleware). Run locally: 7/7 pass. |
| CI | keep fork lanes; upstream's `ensure_fvp_available` moved to `ci-helpers.sh` (fork's ARMFVP_BIN_PATH honour folded in); POSIX lane adds host tests + upstream's CAN bridge / tunnel Python checks; smoke marker now `Control is skipped since input data is not ready.` (HOLD path); runners ubuntu-24.04; release.yml drops the `HEAD:cyclonedds` lookup. |
| .gitmodules | nros + upstream's X5H `rcar_bsp`, `lwip`. |
| CMakeLists BUILD_TEST=4 | upstream path `src/common/dds/network_config.cpp` -> `src/common/net/`. |

### Upstream features present in the tree but NOT wired on this branch

These still require CycloneDDS, which this branch retired:

- `actuation_module/freertos_x5h/` (R-Car X5H CR52, lwIP over RPMsg,
  rpmsg-si channel) and `x5h-freertos-ci.yml` (runs on PRs only).
- FVP CAN UDP tunnel (`--network tap` + CAN output), `run-zephyr-fvp-tap-ci.sh`,
  `run-freertos-vcan-ci.sh`; build.sh `--dds-interface`, `--control-output`,
  `--param-profile`, `--cmake-define`.
- Upstream's raw-DDS late-join operation-mode test in `unit_test.cpp`.

### Not yet verified

- No local nano-ros build of the ported controller: this host has no
  Autoware message AMENT prefix. The fork's CI (`Build and Test`,
  workflow_dispatch on `nano-ros-rebase`) is the compile and boot check.
- Entity count: the node now creates 7 subscriptions (was 5) and 4
  publishers (was 3). The executor arena (`NROS_EXECUTOR_ARENA_SIZE`
  131072, sized from measurement in 9e12a75) has to be re-measured on
  S32Z2/AN536.
- An empty launch param (`value=""`) must reach `declare_parameter` as an
  empty string. If nros drops it, the default "" still yields the build
  default.
- `transient_local` on the opmode reader: honoured by the RMW?

## B. nano-ros provisioning upgrade

### Pin target

Two steps. First bump to **05b7f7d2648f**, the island's proven pin, then to
`main` **375fd91f41**. Both have the same Zephyr (v3.7.0) and
zephyr-lang-rust (404fcef) as af14492fe. After PR #2743 (2026-10-27) is in,
stale `*.json.unprobeable` probe markers (issue 2097) clear themselves. On
an older pin they must be deleted by hand, or the image is sized without
its sidecars.

### Gap table (old -> new -> ASI files -> risk)

| old (af14492fe) | new (main) | ASI files | risk |
|---|---|---|---|
| `<nros/*.hpp>`, `nros::` | `<rclcpp/*.hpp>`, `rclcpp::` (phase-503, no forwarding headers) | common/node/node.hpp, controller_node.{hpp,cpp}, controller_pkg, test/*.cpp (~75 sites) | high (mechanical but wide) |
| `nros::ComponentNode` | `rclcpp::NodeWithTimers<N>` / `rclcpp::Node` with `(rclcpp::NodeHandle)` ctor (#427 W4) | controller_node.hpp, node.hpp (`AsiNode`) | high |
| `create_subscription<M,C,&C::f>`, `create_publisher<M>` by value, `create_timer_in` | `create_subscription_in`, `create_publisher_in`, `create_timer_in_group` (d5075fe415); the OLD names now bind to rclcpp shared_ptr overloads **without a compile error** | controller_node.cpp ctor, platform/freertos/wall_clock.cpp | high (silent meaning change: audit every call) |
| `nros_log_*` C API, `<nros/log.h>` | `rclc_log_*`, `<rclc/log.h>` (phase-492; docs/reference/c-api-rename-map.tsv) | common/logger/logger.hpp | med |
| `nros::init().ok()` | `rclcpp::init_in().ok()` | test/dds_pub.cpp, dds_sub.cpp, unit_test.cpp, dds_loopback_test.cpp | low |
| system.toml `[deploy.*]` | refused (phase-486 W8): `[image.<id>]`, `[board_config.<board>]`, `[host.*]` | controller_bringup/system.toml (4 deploy rows, an536 `domain_id`) | high (parse fails) |
| `nano_ros_entry(... DEPLOY x)` free-form | must agree with the leaf system.toml image (issue 1894) | actuation_module/CMakeLists.txt, freertos_*_entry/CMakeLists.txt | med |
| nros-codegen.toml beside the msg package | discovered ancestor-first from the workspace root (issue 1470) | move autoware_msgs/nros-codegen.toml to the workspace root | med |
| nano-ros as a west project (lockstep with submodule) | `-DZEPHYR_EXTRA_MODULES=<nano-ros>`; Zephyr workspace provisioned in the store (`nros setup zephyr`) | west.yml, build.sh, bootstrap-asi.sh, lockstep check in run-zephyr-fvp-ci.sh | low (old path probably still works) |
| no sync step | `nros sync` before configure (codegen, SystemModel, probe sidecars); `nros sync --check` in CI | build.sh, run-*-ci.sh, bootstrap-asi.sh | med |
| no lock | `nros-sdk.lock` at the project root, committed; only `nros update` moves pins | repo root | low |
| `just setup-cli` only | `just setup-cli` + `just setup-launch-resolve` (sync needs nros-launch-resolve) | run-freertos-posix-ci.sh Phase 0 already builds both by cargo | low |
| per-package `nros_generate_interfaces` | still supported; island pattern is msg packages + one `nros_find_interfaces(... CODEGEN_CONFIG)` union | autoware_msgs/CMakeLists.txt | low (keep, migrate later) |
| 2 roles (pkg + entry) | 3 roles: Node pkg (library, package.xml), Bringup pkg (system.toml, launch, no code), Image (`[image.<id>]` row) | controller_pkg, controller_bringup, freertos_*_entry | med (entries become image rows) |

Unchanged (verified): `NROS_COMPONENT`, `NROS_SUBSCRIBE`, `QoS` builders,
`create_callback_group`, `create_wall_timer`, `ok()`, `publish().ok()`,
`FixedSequence`/`FixedString` (namespace only), `NROS_EXECUTOR_ARENA_SIZE` /
`NROS_SUBSCRIPTION_BUFFER_SIZE` (env still wins), `[tiers.*]` +
`group_tiers` + `features=["param_services"]`, optional contract sidecar,
the four ASI boards and the armcr52 toolchain, `[source.freertos-kernel]`.

To settle at the first configure on the new pin: whether the message set
needs `[defaults]` caps (the island needed 24 types); whether the test
images' cyclonedds `_genroot` C names (now `pkg__msg__Type`) still exist;
where a per-image `domain_id` goes; `nros setup board <id>` spelling.

### Work items

1. Bump to 05b7f7d (submodule + west.yml together), rewrite system.toml
   to `[image.*]`, add `nros sync` to build.sh/CI, move nros-codegen.toml.
2. Rename `nros::` to `rclcpp::`; move the controller to
   `NodeWithTimers<N>` and the `_in` entity verbs; audit every
   `create_*` call (silent overload change).
3. Logger to `rclc_log_*`; tests to `init_in()`.
4. Commit `nros-sdk.lock`; drop west lockstep once `ZEPHYR_EXTRA_MODULES` is
   in use.
5. Re-measure the arena (7 subs / 4 pubs) on AN536 and S32Z2.
6. Bump to nano-ros main 375fd91f41.

### Progress

#### Step 1 - 05b7f7d2648f (2026-10-30)

Done on `nano-ros-rebase`; CI run 41083138193 (c837c49) green on all three
lanes. Commits, in order:

- pin: modules/nros and west.yml together (LOCKSTEP kept; the Zephyr lane
  still consumes nano-ros as a west project). This commit also carries the
  nros-codegen.toml move (staged early by mistake; the follow-up commit
  only fixes the path autoware_msgs passes).
- C++ API: `nros::ComponentNode` -> `rclcpp::NodeWithTimers<1>` (controller,
  unit_test, dds_sub) or `rclcpp::Node` (dds_pub, dds_loopback_test);
  `create_subscription<M,C,&C::f>` -> `create_subscription_in`,
  `create_publisher<M>` -> `create_publisher_in`, `create_timer_in` ->
  `create_timer_in_group`, `create_wall_timer<C,&C::f>(ms)` ->
  `create_wall_timer_in`, `nros::init()` -> `rclcpp::init_in()`,
  `<nros/*.hpp>` -> `<rclcpp/rclcpp.hpp>`; `AsiNode` = `rclcpp::Node`.
  Every call site was converted by hand: the old names still compile.
- logger: `nros_log_*` -> `rclc_log_*`, `<rclc/log.h>`,
  `rcl_log_severity_t`, `RCLC_LOG_SEVERITY_*`.
- bringup: `[deploy.*]` -> `[image.<id>]` with nano-ros board ids (fvp ->
  `fvp-aemv8r-smp`, freertos-posix, s32z2 -> `s32z270-freertos`, an536 ->
  `mps3-an536-freertos`); `kind` and the Zephyr `target` are gone. Image
  ids are unchanged, so build.sh's `NROS_DEPLOY` and the entries' `DEPLOY`
  tokens did not move.
- nros-codegen.toml at the workspace root (`actuation_module/`).
- build: `NANO_ROS_PLATFORM/BOARD/FEATURES` are refused (phase-484 W8) ->
  `NROS_*`; the FreeRTOS kernel is provisioned into the SDK store, so
  build.sh asks `nros locate freertos-kernel` (index pinned) for
  `FREERTOS_DIR`.
- FreeRTOS: `include/platform/freertos/FreeRTOSConfig.h` (a stale copy of
  the board's) deleted. It shadowed the board config for the entry TUs
  only; with configSTACK_DEPTH_TYPE uint16_t vs uint32_t the image
  segfaulted in xTaskCreateStatic. The S32Z2 config honours
  `NROS_FREERTOS_LEVEL_IMAGE` (issue 2017; `freertos_run_tiers.c` #errors
  otherwise).
- `actuation_module/nros-sdk.lock` committed (qemu 11.0.0-nros7,
  arm-none-eabi-gcc 13.2-nros5, corrosion 0.6.1-nros1), written by
  `nros setup --index ../modules/nros/nros-sdk-index.toml --tool ...` run
  in `actuation_module/`; the CI scripts provision from there.
- CI: every lane provisions corrosion (a configure no longer fetches it);
  build.sh's Zephyr lane runs `nros sync .` before west (a missing
  SystemModel is refused since issue 1575); the FreeRTOS lanes run
  `nros sync --check .` after the build; both cross lanes add their Rust
  target to the toolchain nano-ros pins (`rust-toolchain.toml`, 1.99.0),
  which corrosion's FindRust checks.
- Zephyr: `find_package(nano_ros)` sets `NROS_DEPLOY` /
  `NROS_LEAF_IMAGE_ID` from the app dir's own system.toml; actuation_module
  has none, so both came back empty and `nros ws board-facts` refused four
  images as ambiguous. actuation_module/CMakeLists.txt restores `fvp`.
  It also sets `CONFIG_NROS_CAPABILITY_PARAM_SERVICES` and
  `CONFIG_NROS_PARAM_STORE` before `find_package(Zephyr)`, as the
  application `nros build` generates would.
- CAN test: nano-ros now starts the `zephyr,canbus` controller in an
  APPLICATION SYS_INIT (RFC-0109 D10), and Zephyr changes the mode of a
  stopped controller only, so can_output_test stops it before
  `can_set_mode(LOOPBACK)`.
- tap profile: states `CONFIG_NROS_DOMAIN_ID=2` beside
  `CONFIG_NROS_CYCLONE_DOMAIN_ID=2` (a disagreement is refused at
  configure since issue 1550).
- logger: on Zephyr the island's `log_*` lines go to printk. The SMP FVP
  image delivered the first four nros_log records and then none (four is
  `NROS_LOG_EARLY_RECORDS`, the ring issue 2000 parks records in while
  another thread is inside a sink), although the controller ran on - a
  printk probe beside every record showed the full boot and the control
  loop. Seen on 05b7f7d and on main 9be6bcfa4f. Upstream bug, not filed
  yet; Rust-side nros_log records on that image are still lost.

Behaviour checks (freertos-posix, local, ROS_DOMAIN_ID 77, CycloneDDS on
`lo`, host ROS 2 Humble + Autoware 1.5.0 msgs):

- `ros2 node info /controller`: 7 subscribers, 4 publishers, the expected
  topics and types.
- subscriptions receive: with `ros2 topic pub` on
  /vehicle/status/steering_status and /localization/acceleration the
  "Waiting for steering/acceleration data" lines stop; stopping the
  publishers latches `SI_STOP: acceleration`, as designed.
- timer: `ros2 topic hz /control/trajectory_follower/control_cmd` =
  30.6 Hz (min 28 ms, max 52 ms) for `ctrl_period` 0.03 s.
- AN536 under QEMU: every CI marker, `tier priority set tier=control
  prio=7`, `kernel time slicing OFF`, heap peak 539 KB of 32 MB.

Memory (runtime advisory, arena forced to 4 MiB): 91,344 B claimed at
first spin on freertos-posix, 90,440 B on freertos-an536 (was 88,780 /
88,484). `NROS_EXECUTOR_ARENA_SIZE` stays 131072. New at this pin: the
parameter store is carved from the executor backing, 256 slots =
2,285,568 B (posix) / 2,246,656 B (an536) plus ~35 KB of services. That
is `NROS_MAX_PARAMETERS=256` x ~8.9 KB per slot; it fits the AN536
(32 MB heap) and has to be checked against the S32Z2 memory map.

Known gaps at this pin:

- `nros sync` reports "no producer for controller_pkg::controller": the
  metadata probe panics in `census_hooks.rs` because the metadata
  recorder holds 32 entities (`DEFAULT_MAX_METADATA_ENTITIES`) and the
  controller declares 150+ parameters. Non-fatal (the build and runtime
  are unaffected), but the image has no source metadata; unchanged on
  nano-ros main as of 96c5736474.
- `NROS_ENTRY_SPIN_MS` is read only by the Rust `nros::main!`; the C++
  FreeRTOS entry ignores it, so the posix smoke runs to the 60 s CI
  timeout (accepted by `is_success_or_timeout`). Not new: the af14492 run
  41042777043 also took the full 60 s.
- 11 linked-only types carry no derived bound (sizing descriptor
  `[types.refused]`); a warning, no caps were demanded by codegen.

## C. Contribute back to autowarefoundation (ranked)

Upstream conventions, from the log and PRs:

- Conventional Commits; squash-merge with `(#NN)`.
- `Signed-off-by` on every commit (DCO).
- SPDX `Apache-2.0` headers with `Copyright (c) <year>, <org>`.
- PR body is Problem / Root cause / Fix / Validation with hardware
  evidence (see #42).
- CI lanes: Zephyr FVP, Zephyr FVP TAP, FreeRTOS POSIX, FreeRTOS POSIX vcan.
- Upstream accepts large features (#45 +8.5k, #66 +3k) when they are
  opt-in and keep the existing lanes green.

| # | candidate | size | source | prerequisites | PR shape |
|---|---|---|---|---|---|
| 1 | Pin lockstep / reachability check pattern and FVP-helper honouring a preset `ARMFVP_BIN_PATH` | ~15 lines | ci-helpers.sh (this branch) | none | `ci: reuse a preset ARMFVP_BIN_PATH` |
| 2 | Stack-headroom check that fails on an empty report | ~20 lines | 0bfc7f5 / 477cd35 | upstream needs a stack report first (Zephyr `CONFIG_THREAD_ANALYZER`) | `ci:` small |
| 3 | Per-input throttle slots in `processData()` (one shared lambda slot hid four missing inputs, issue 0836) | ~20 lines | controller_node.cpp processData | none, applies to the DDS controller as-is | `fix(controller):` |
| 4 | Odometry/accel string clearing on the DDS loan path; `TrajectoryMsg` header copy | small | already upstream (#48) | - | drop |
| 5 | Host-test CMake project independent of the FreeRTOS tree | ~50 lines | actuation_module/test/host | none | `test: build the host unit tests standalone` (+ CI step) |
| 6 | CTF tracing profile (stats / CTF / RAM ring, app markers, Zephyr patch) | medium | tracing*.conf, common/diag, patches/zephyr, build.sh --trace* | needs Zephyr patch upstreamed or carried; middleware-independent | `feat(trace):` one PR per layer |
| 7 | QEMU mps3-an536 emulated Cortex-R52 lane | medium | freertos_an536_entry, run-freertos-an536-ci.sh | currently nano-ros-only; DDS port of the board glue needed | later, after 8 |
| 8 | nano-ros as an opt-in middleware backend | large | build, msgs, controller, platform commits | see below | RFC issue first, then 3-4 PRs |
| 9 | Docs: nano-ros migration and RT evaluation notes | medium | documentation/design/* | after 8 | `docs:` |

### Making nano-ros acceptable upstream (item 8)

Upstream will not take a change that deletes CycloneDDS. Its X5H, CAN
tunnel and vcan lanes and its partners' rigs depend on it. The
contribution has to be a second backend:

- Keep `common/dds` + the DDS `Node` shim + `main.cpp` as the default.
  Add a `CONFIG_ASI_MIDDLEWARE_NROS` (Zephyr) / `--middleware nros`
  (build.sh) switch that selects `nros::ComponentNode` (later
  `rclcpp::Node`) and the generated entry.
- Put a thin node facade between the controller and both backends so that
  the controller body is single-source. Today's port shows the minimum
  difference is three things: the callback signature (typed member vs
  `(msg*, void*)`), sequence access (`FixedSequence` vs `_length/_buffer`),
  and the publisher type. A `common/node/node.hpp` with two
  implementations could hide all three. MPC/PID already only see `AsiNode&`.
- Messages: keep the IDL for DDS. Generate nros from the same `.msg`
  sources (AMENT) and keep the `.msg` twins for the 4 supervision types.
- CI: a fifth lane `FreeRTOS POSIX (nano-ros)` next to the four existing
  ones, all four DDS lanes unchanged.
- Order:
  1. An RFC issue with the measurements (the paper numbers stay out of this repo).
  2. A PR that adds the facade with no behaviour change on DDS.
  3. A PR that adds the nros backend + lane.
  4. A PR that adds the Zephyr nros lane.
  5. Docs.
- Prerequisite: finish B first. Upstreaming on the old `nros::` API would
  rename everything a month later.

### MRM module beside actuation_module (phase-14 idea)

The island's MRM chain (`autoware_mrm_handler`,
`autoware_mrm_emergency_stop_operator`,
`autoware_mrm_comfortable_stop_operator`, `autoware_stop_mode_operator`,
~1.8 kLOC on nano-ros) is Autoware's system fallback:

- It reacts to `/system/operation_mode/availability`, which Autoware's
  diagnostic graph produces.
- It drives the stop through `/system/mrm/*/operate` services.
- It emits `/system/emergency/control_cmd`, `/system/fail_safe/mrm_state`
  and hazard lights.

Upstream's supervisor (#66, #57, 9eb7952) is a different layer. It is the
actuation authority's own watchdog: per-source arrival timeouts, the
VisionPilot heartbeat, and a latched SI_STOP with a decel ramp. It works
when the main ECU is dead.

- Overlap: both end in a decelerating stop command. The emergency stop
  operator's jerk-limited ramp and `supervision::StopRamp` solve the same
  problem.
- Complement: MRM covers "Autoware alive but degraded" (planned,
  comfortable or emergency stop, MRM state reported back to Autoware).
  SI_STOP covers "inputs gone".
- Fit: upstream's contract says the SI is the single actuation authority
  and ApprovedRequest is the only actuator-facing output. An MRM module
  must therefore NOT be a second writer of control_cmd. Its emergency
  command enters the actuation module's gate as a candidate source (a third
  `SelectedSource`, e.g. `MRM`) or as a SI_STOP trigger, and
  `/system/fail_safe/mrm_state` is published beside ApprovedRequest.
- Blockers:
  - The MRM chain uses services, which upstream's raw-Cyclone shim does
    not support. It therefore depends on item 8 (the nros backend) or on
    adding service support to the DDS shim.
  - availability needs Autoware's diagnostic graph on the main ECU.
- Proposed shape:
  - `mrm_module/` beside `actuation_module/`, built from the island's
    packages.
  - First an issue describing the arbitration rule against
    vp_si_control_contract, then a PR after item 8 lands.

## Open decisions for the user

1. Keep the squashed `nano-ros-rebase` as the new working line (and later
   fast-forward `main` to it), or keep `nano-ros` as the line and treat this
   branch as the upstream-facing view only.
2. X5H / CAN tunnel / vcan: port them to nano-ros, or accept them as
   DDS-only and wait for the dual-backend work (item 8)?
3. Upstream item 8: is a dual-backend facade (two maintained paths) worth
   it, versus keeping nano-ros fork-only and upstreaming items 1-6 only?
4. nano-ros bump: stop at the island's 05b7f7d, or go to main 375fd91f41
   at once?
5. DCO: commits for upstream need `Signed-off-by` from a human author.
