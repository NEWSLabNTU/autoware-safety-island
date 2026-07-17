# Phase 3 — reconcile with upstream FVP/FreeRTOS work + migrate to modern nano-ros

**Status.** Proposed (2026-07-16). The `nano-ros` branch was rebased onto
upstream `main` (`a76b63f`) on 2026-07-16; the rebase surfaced that upstream
evolved substantially while the port sat on a June pin, and that one replay
silently clobbered upstream work (see W1). nano-ros itself moved through
phases 248/256/263/287/291 — every wall Phase 2 recorded is closed upstream.

**Goal.** One branch that (a) keeps ALL of upstream's FVP/FreeRTOS/S32Z2/CAN
work, (b) consumes nano-ros in the current canonical shape (RFC-0048 ament
verbs, Entry pkg, `nros setup` provisioning), and (c) scopes the nano-ros RMW
to where it is proven (Zephyr first, FreeRTOS as a follow-up wave), so the
branch is upstreamable instead of a divergent fork.

**Counterpart.** nano-ros phase-292 (ASI reference-consumer revisit) tracks
the upstream-side work items this phase surfaces.

---

## Gap summary (2026-07-16 review)

| # | Gap | Class |
|---|---|---|
| G0 | **`build.sh` silently clobbered by the rebase**: the branch's phase-1 83%-rewrite replayed wholesale over upstream's new 4-runtime driver (`--platform {zephyr-fvp,zephyr-s32z,freertos-posix,freertos-s32z2}`, `--network tap`, `-d`); no conflict was flagged (rewrite detection). Upstream's FVP tap profile + cyclonedds host/target build functions are gone from the branch. | rebase damage |
| G1 | **cyclonedds submodule deletion breaks upstream's FreeRTOS runtimes**: right call for the Zephyr nano-ros path, but `freertos-posix`/`freertos-s32z2` (which post-date the delete) build the vendored tree + the same raw-DDS `dds.hpp` the branch removes. | scope collision |
| G2 | **Entry mechanics predate nano-ros phase-287**: root-CMake `nano_ros_node_register(... DEPLOY zephyr)` typed carrier + forced `set(NANO_ROS_PLATFORM zephyr)` + manual `include(NanoRosNodeRegister.cmake)` + hand-wired `zephyr_interface` compile context. Canonical now: `find_package(nano_ros)` under west supplies the verbs (287-W6); a LAUNCH-only Entry pkg via `nano_ros_add_executable(BOARD zephyr LAUNCH ... TYPED)`. This is exactly the Phase-2.D wall — solved upstream. | stale consumption |
| G3 | **Pin `a7b6eac5c` (June)**: predates RFC-0044 param hardening, 248 RMW-agnosticism, 256 config SSoT, 263 workspace examples, 287 ament shape, the #206 env-overlay/silent-domain-0 fix, 291. Bootstrap scripts carry "pin predates `nros setup board`" fallbacks that are all dead weight post-bump. | stale pin |
| G4 | **CI workflows gutted** relative to upstream's (branch simplified build-ci/release by ~80 lines each while upstream evolved them for the 4 targets). | rebase damage (soft) |
| G5 | **#42 KEEP_LAST-1 lesson unported**: upstream's heap-exhaustion fix (10 Hz producer × ~1.7 Hz consumer × deep reader history × ~8.8 KiB trajectories → OOM → silent board death) died with the deleted raw-DDS wrapper; the nros-side subscription QoS has not been audited for the depth-1 bound. | correctness carry-over |
| G6 | Phase-1 residue: `nano_ros_smoke/` app, dual-mode `messages.hpp` descriptor shims, `bootstrap-nano-ros-shim.sh`. | cleanup |
| G7 | `zephyr-s32z` (s32z270dc2_rtu0_r52) has no nano-ros board crate — `nano_ros_use_board()` covers FVP only. | upstream gap (nano-ros phase-292 W3) |
| — | NOT gaps: `controller_pkg`/`controller_bringup` identity + `system.toml` (schema v0.1, frozen) conform to current nano-ros; board conf HWMv2 renames match upstream exactly; `nano_ros_use_board(fvp-aemv8r-smp)` is still the current mechanism. | |

## Waves

### W1 — restore upstream's driver; re-graft nano-ros into it (G0, G1, G4)

> As-landed (2026-07-16): upstream build.sh restored; nano-ros grafted into
> the zephyr platforms (nros CLI bootstrap, `_NANO_ROS_CODEGEN_TOOL`,
> `nano_ros_overlay.conf`, HWMv2 board ids/conf basenames); cyclonedds
> submodule + the raw-DDS wrapper headers + `src/main.cpp` restored for the
> FreeRTOS platforms. The shared sources went DUAL-MODE on
> `ASI_USE_NANO_ROS` (defined by the Zephyr build only): `messages.hpp`
> (+ a borrow-based `to_raw()` on the dds wrapper), `clock.hpp`,
> `common/node/node.hpp` (defines the `AsiNode` argument alias both modes),
> the shallow vendored files take `AsiNode &`, and
> `controller_node.{hpp,cpp}` carry both bodies whole. `autoware_msgs`
> selects nros codegen vs upstream idlc by `COMMAND nros_generate_interfaces`
> (per-build, so W5 can flip FreeRTOS later without touching it).
> PROOF: `./build.sh --platform freertos-posix` links `actuation_freertos`
> (RC 0). The zephyr platform still walls at the OLD pin (expected — that is
> exactly what W2's bump fixes).
- [x] W1.a Restore upstream `main`'s `build.sh` as the base. Re-graft the
  nano-ros pieces INTO the `--platform zephyr-fvp` / `zephyr-s32z` paths:
  the `nros` CLI bootstrap hook, `-D_NANO_ROS_CODEGEN_TOOL`, the
  `nano_ros_overlay.conf` EXTRA_CONF_FILE. The driver's interface
  (`--platform/--network/-d`) is upstream's; nano-ros is an implementation
  detail of the Zephyr platforms.
- [x] W1.b Restore the `cyclonedds` submodule + host/target build functions,
  SCOPED to the freertos platforms (the Zephyr path stays cyclonedds-free —
  the nano-ros module provides the RMW). `freertos-posix` and
  `freertos-s32z2` must build exactly as on upstream `main`.
- [x] W1.c (reconciled; first GHA run still to validate — rust step added to zephyr jobs) Reconcile CI: upstream's workflows as base, nano-ros zephyr job
  additions re-applied.
- [x] W1.d Verify the FVP demo flow doc-for-doc: tap setup → `docker compose
  up` → `west build -d ... --target run` → bridge `ros2 topic echo`.

### W2 — pin bump + canonical consumption (G2, G3, G6)

> Checkpoint (2026-07-17): pin bumped `a7b6eac5c` → `4875289f6`;
> `./build.sh --platform zephyr-fvp` links `zephyr.elf` — the Phase-2.D
> compile-context wall is GONE at the current pin (287-W6), and consumer
> wall #1 (cyclone ipv4-compat force-include global on 3.7 breaking
> llext-edk's `$<JOIN>`) was fixed on nano-ros main (`4875289f6`,
> phase-292 W2 intake #1). The OLD carrier entry path builds as-is; W2.b
> (canonical Entry pkg) proceeds as modernization. Note: `west update`
> could not fetch a bare sha from the module remote (west fetch fallback
> failed; manual `git fetch newslab main && git checkout <sha>` needed) —
> track as a bootstrap-asi.sh hardening item.
>
> W2 COMPLETE (2026-07-17): the canonical shape landed GREEN on the first
> try — `find_package(nano_ros REQUIRED HINTS ${NROS_REPO_DIR})` +
> carrier-less `nano_ros_add_node(controller ...)` + LAUNCH-only
> `nano_ros_add_executable(actuation_entry BOARD zephyr LAUNCH
> "controller_bringup:system.launch.xml" TYPED)`. The `zephyr_interface`
> hand-glue is GONE (clean rebuild proves 287-W6's verbs supply the full
> compile context — the exact 2.D wall, now closed). Retired:
> `nano_ros_smoke/`, `bootstrap-nano-ros-shim.sh` (CLI ensure inlined into
> build.sh), the pre-215.J bootstrap fallback. The Entry pkg lives as the
> workspace root's verb call rather than a separate `src/fvp_entry/` dir —
> the actuation_module root IS the Zephyr app, matching the
> `ws-realtime-cpp/src/zephyr_entry` structure one level up. Regression
> pair green: `--platform freertos-posix` AND `--platform zephyr-fvp` from
> the same tree. Wall intake total for the bump: ONE (the llext-edk genex,
> fixed upstream same-day).
- [x] W2.a Bump `west.yml` nano-ros revision to current main;
  `nros setup zephyr --rmw cyclonedds`; delete the pre-215.J fallbacks in
  `bootstrap-asi.sh` and retire `bootstrap-nano-ros-shim.sh` (the CLI build
  moves behind `nros setup` / the build.sh hook).
- [x] W2.b New Entry pkg `actuation_module/src/fvp_entry/`:
  `find_package(Zephyr)` + `find_package(nano_ros)` +
  `add_subdirectory(../controller_pkg)` +
  `nano_ros_add_executable(fvp_entry BOARD zephyr LAUNCH
  "controller_bringup:system.launch.xml" TYPED)` — the
  `ws-realtime-cpp/src/zephyr_entry` shape. Retire the root-CMake carrier
  path, the `NANO_ROS_PLATFORM` force, and the `zephyr_interface` hand-glue
  (287-W6 makes the verbs zephyr-aware).
- [x] W2.c Retire `nano_ros_smoke/` + the dual-mode `messages.hpp`
  descriptor shims once W2.b builds.
- [x] W2.d Reference-consumer contract: every wall the bump surfaces is
  filed against nano-ros (phase-292 W2 intake) with a minimal repro, like
  the Phase-2.D "9 consumer-surfaced gaps" round.

### W3 — FVP runtime proof (G5)

> Status (2026-07-17): `--network tap` image BUILDS green (with the W3.b QoS
> fix baked). W3.b DONE: all five controller input subscriptions bound to
> KEEP_LAST depth 1 (`nros::QoS::default_profile().keep_last(1)`) — the nros
> default was depth 10 (safe vs the raw-DDS 500, but still 9 stale buffered
> trajectories on an only-latest input). The FVP BOOT + compose bridge are
> HOST-GATED: `FVP_BaseR_AEMv8R` is license-gated (developer.arm.com; put on
> PATH or set `ARMFVP_BIN_PATH`), tap0 setup needs sudo (commands in
> demo/README.md), and the demo compose stack needs the Autoware images
> pulled. Runtime verification resumes when the model is installed.
- [x] W3.a (2026-07-17) **DONE — end-to-end closed loop on the FVP.**
  Final leg: demo compose stack (autoware planning sim + domain bridge) up,
  island pinned to DDS domain 2 (tap conf), ego seeded via `/initialpose`
  (x 3722.16, y 73723.1, ori z 0.777 w 0.629) + goal 30 m along heading →
  trajectory at 10 Hz through the bridge → firmware MPC engages (emergency
  stop on spawn-position tracking error — controller logic live) →
  `/control/trajectory_follower/control_cmd` back on domain 1 at ~26 Hz.
  Notes: 2026-07-17 later same day — **stock SMP-4 image validated**:
  nano-ros wall #6 resolved (duplicate of wall #9, the mutex-pool
  exhaustion), full closed loop on the 4-core build at ~18 Hz
  control_cmd, zero faults over 30+ min sim. No .config surgery needed.
  Firmware still unicast-only (IGMP join fails; SPDP converges);
  spurious boot-time `ComponentNode failed at ? (code=0)` print tracked
  as nano-ros issue 0230.
  Earlier same-day: firmware side — the controller BOOTS AND
  SPINS on FVP_BaseR_AEMv8R 11.31.28 (single-core image): cyclone
  participant up, 74 launch params seeded, all 5 subscriptions +
  publishers + timers created, steady "Control is skipped since input
  data is not ready" idle, SPDP streaming on tap0. Getting there took
  eight consumer walls, all intaken/fixed on nano-ros main (phase-292 W2
  intake log #2–#8) plus ASI-side wiring in this repo: FVP
  `bp.smsc_91c111.enabled=1` (build.sh, the model's NIC is off by
  default), `NROS_MAX_PARAMETERS=256` / `NROS_EXECUTOR_MAX_CBS=16` /
  `NROS_SUBSCRIPTION_BUFFER_SIZE=16384` build-time knobs (build.sh),
  stub `package.xml` per vendored msg_ros package (rosidl_adapter
  requires one for descriptor IDL generation). REMAINING: multicast
  join error -1 (IGMP — image runs unicast-only; peers must reach us by
  unicast SPDP), SMP-4 crash (nano-ros wall #6 — single-core image in
  the meantime), and the demo compose bridge delivery check
  (`/control/trajectory_follower/control_cmd` end-to-end).
- [x] W3.b **QoS audit (#42 carry-over)**: bound every nros subscription the
  controller creates (trajectory, kinematic state, acceleration, operation
  mode, steering) to history depth 1 (or the nros equivalent) and verify
  under a real >1400-byte trajectory stream that heap stays bounded.
- [ ] W3.c Soak: the Phase-2.D real-run checkpoint scenario re-run on the
  modern stack; record deltas.

> Runbook notes for W3.c / future runs (2026-07-17): interactive FVP runs
> need `-C cache_state_modelled=0` — with the Zephyr-default `=1` the model
> fast-forwards idle but crawls ~1000x under busy code (a "hang" at
> `net_config: Initializing network` is usually just this). Headless demo
> bring-up without rviz: seed `/initialpose`
> (x 3722.16, y 73723.1, ori z 0.777 w 0.629 on sample-map-planning), then
> `/planning/mission_planning/goal` ~30 m along the ego heading
> (x 3715.9, y 73752.5, same orientation); probe with
> `ros2 topic hz /control/trajectory_follower/control_cmd` inside the
> autoware container (`source /opt/autoware/setup.bash`). Open upstream
> items tracked in nano-ros: issue 0231 (IGMP join → firmware unicast-only,
> tap must stay promiscuous), 0230 (spurious SMP boot FATAL print), 0232
> (FVP runtime lane).

### W3.b — SystemModel canonical-path pilot (nano-ros phase-296 W4.3)
- [x] Resolve the launch + system.toml into a committed SystemModel
  (`controller_bringup/config/system_model.yaml` + record companion,
  `play_launch resolve launch/system.launch.xml --system system.toml`);
  params (`control_output`) ride the model (play_launch model_builder
  producer fix), deploy carries `kind: zephyr` for board-family slicing.
- [x] Entry bakes from the model: `nano_ros_add_executable(... MODEL
  "<config/system_model.yaml>" TYPED)` replaces the LAUNCH keyword;
  nano-ros pin bumped to 4ea1f4a2e (MODEL keyword + plan_from_model +
  kind-family slicing).
- [ ] FVP rebuild from the model-baked entry + tap-demo smoke (same W3
  runbook) — validates phase-296 W4.3's done-when on AVH/FVP.

### W4 — zephyr-s32z parity (G7; hardware-gated)
- [ ] W4.a Consume nano-ros's s32z board crate once phase-292 W3 lands
  (`nano_ros_use_board(s32z270dc2-rtu0-r52)`), replacing the hand-glued
  EXTRA_DTC_OVERLAY path.

### W5 — FreeRTOS targets onto nano-ros RMW (follow-up; separate acceptance)
- [ ] W5.a `freertos-posix` first: consume nano-ros's freertos platform +
  cyclone RMW infra instead of the vendored cyclonedds + raw `dds.hpp`;
  needs nano-ros-side support for the POSIX-sim FreeRTOS flavor
  (phase-292 W4 scoping).
- [ ] W5.b `freertos-s32z2` after: NETC/hardware specifics; retires the
  vendored cyclonedds submodule for good.

## Acceptance
- All four upstream runtime targets build from ONE branch; zephyr targets on
  nano-ros, freertos targets unchanged (until W5).
- FVP tap demo end-to-end green on the modern nano-ros pin.
- No hand-glued Zephyr compile-context in the node pkg; Entry is
  `nano_ros_add_executable` one-liner shape.
- QoS depth audit recorded; heap bounded under real trajectory load.
