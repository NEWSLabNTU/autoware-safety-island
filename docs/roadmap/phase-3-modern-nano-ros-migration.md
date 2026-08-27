# Phase 3 — reconcile with upstream FVP/FreeRTOS work + migrate to modern nano-ros

**Status.** Proposed (2026-07-16). The `nano-ros` branch was rebased onto
upstream `main` (`a76b63f`) on 2026-07-16; the rebase surfaced that upstream
evolved substantially while the port sat on a June pin, and that one replay
silently clobbered upstream work (see W1). nano-ros itself moved through
phases 248/256/263/287/291 — every wall Phase 2 recorded is closed upstream.

## RESOLVED (2026-08-27): the FVP tap demo drives again

`scripts/run-tap-demo.sh --drive` completes: **ARRIVED (route_state=3)**, peak
2.19 m/s, final position within 0.1 m of the goal, control_cmd streaming to
Autoware at ~8 Hz. The island boots in 8 s.

**Root cause: nano-ros `3d52070ec`, "fix(zephyr): RMW snippet sizing becomes
overridable, not absolute".** A snippet is applied as `EXTRA_CONF_FILE`, which
Zephyr merges AFTER the board conf, so the nros-cyclonedds snippet's resource
sizes had been BEATING every board. That commit moved them to Kconfig defaults
a board may override — correct for hardware (the numbers are host-scale; an
S32K344 with 320 KiB of SRAM could not argue with them), and it explicitly
kept the numbers unchanged.

What it changed for us is WHO decides. ASI had never declared these, so it had
been silently living on the snippet's values, and lost them all at once:

| symbol | was (forced by snippet) | became |
| --- | --- | --- |
| `COMMON_LIBC_MALLOC_ARENA_SIZE` | 16 MiB | **absent** |
| `HEAP_MEM_POOL_SIZE` | 4 MiB | 192 KiB |
| `SYSTEM_WORKQUEUE_STACK_SIZE` | 8192 | 4096 |
| `MAIN_STACK_SIZE` | 512 KiB | 32 KiB (ASI's own `prj_actuation.conf`) |

The image then blocked 1.16 s into boot on an allocation that never completes.
The fix is one conf block in
`boards/fvp_baser_aemv8r_fvp_aemv8r_aarch64_smp_actuation.conf`: ASI now
declares what it needs, which is exactly the freedom the upstream change was
for.

### How it was found, and what nearly prevented it

**It was never spinning.** The FVP sat at 100% host CPU, which read as a
livelock; attaching over the model's Iris debug server
(`scripts/fvp-where-stuck.py`) showed all four cores at
`zephyr/arch/arm64/core/cpu_idle.S:24` — WFI — on every resample. Fast Models
burn a host thread while the guest idles. That one measurement turned the
question from "what loop is this" into "what allocation never returns", and it
cost minutes where the bisect cost hours.

**The first bisect was invalid.** Run against ASI's own history it converged on
a docs-only commit whose pin is identical on both sides. The signal was flaky
because the clock re-sync spins on this model (7780 re-syncs in one run), so
whether a boot won that race was luck. Disabling it made the signal
deterministic.

**The second bisect needed an isolated checkout.** `modules/nros` is another
session's working tree and carried uncommitted edits to `zephyr/Kconfig` and
`zephyr/cmake/nros_rmw_zenoh.cmake` — Zephyr build inputs — so every probe run
there silently included them. A separate clone with its own submodules gave a
clean signal: good pins boot in 7-12 s, bad pins never do.

Three environment traps cost a step each and are worth knowing:
`ARMFVP_BIN_PATH` and `ARMFVP_EXTRA_FLAGS` are baked at CONFIGURE time (setting
them later gives `ARMFVP-NOTFOUND`); `build.sh` sets `AMENT_PREFIX_PATH` but
never `PYTHONPATH`, so a fresh clone cannot import `rosidl_adapter`; and moving
the pin makes the in-tree `nros` CLI stale by its own source-stamp gate, which
`NROS_SKIP_STALE_CHECK=1` exists to override for exactly this experiment.

Note the FVP takes the LAST occurrence of a duplicated `-C` parameter, not the
first — verified with `--list-params`. An earlier note in this repo claimed the
opposite and sent one investigation chasing a slowdown that was not there.

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
> autoware container (`source /opt/autoware/setup.bash`). Upstream items
> in nano-ros: 0231 RESOLVED 2026-07-17 (Zephyr multicast join fixed —
> `ip_mreqn` + EALREADY, cyclonedds fork 1d794c0a; closed loop re-verified
> at ~19 Hz; the promiscuous-tap requirement is likely obsolete — verify
> once with promisc off, needs root); still open: 0230 (spurious SMP boot
> FATAL print), 0232 (FVP runtime lane).

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
- [x] FVP rebuild from the model-baked entry + tap-demo smoke (same W3
  runbook) — validates phase-296 W4.3's done-when on AVH/FVP.
  (2026-08-20, on the eace28852 pin + submodule layout: tap image
  rebuilt with `-C cache_state_modelled=0` baked, boot markers at
  0.2 s sim time, compose stack up, initialpose + goal seeded headless
  per runbook → trajectory ~10 Hz through the bridge →
  `/control/trajectory_follower/control_cmd` back on domain 1 at
  ~19–22 Hz; MPC engages and emergency-stops on the spawn-position
  tracking error, same as the W3.a baseline.)

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

### W6 — 2026-08-20 pin bump 7dfe4fe4e → eace28852 (+ submodule adoption)

Main had NOT moved (`a76b63f` = merge-base = origin/main); no rebase.
nano-ros jumped ~2394 commits. nano-ros became a git SUBMODULE at
`modules/nros` in lockstep with the west.yml revision (west adopts the
checkout in place; `.gitignore` un-ignores `modules/nros`). Provisioning
follows the nano-ros book's board-crate consumer shape
(`book/src/porting/board-crate-import.md`, written for the ASI
archetype). Host idlc now comes from the nros SDK store
(`nros setup fvp-aemv8r-smp --rmw cyclonedds`). All six build modes
re-verified green (full, unit-test, dds-loopback, can-output,
dds-publisher, dds-subscriber), and the full 5-phase CI runtime script
(`run-zephyr-fvp-ci.sh`) passed locally on FVP 11.31.28: controller
boot markers, `=== All Tests Passed ===`, DDS loopback, CAN output,
tap build smoke — "Zephyr FVP runtime validation OK".

Wall ledger (symptom → cause → fix):

1. **`nros setup board fvp-aemv8r-smp` fails: "no board crate at
   packages/boards/nros-board-fvp-aemv8r-smp"** — run_board (setup.rs)
   still resolves the pre-phase-337 board-crate layout; bundle boards
   live at `packages/boards/nros-board-zephyr/boards/<name>/` and the
   bundle-aware resolver exists (`nros board info` uses it). UNFIXED at
   upstream HEAD (12f5d1d8f). ASI: bootstrap-asi.sh inlines the four
   run_board steps (RMW source, 3.7 patch set, rustup target, lang-rust
   check). → UPSTREAM ISSUE CANDIDATE (fix the class: `nros ws
   board-facts` has the same bundle-blind descriptor match, see #3).
2. **Configure FATAL: "host Cyclone idlc not found"** — the pin's
   cyclonedds cmake resolves idlc from the nros SDK store before PATH.
   Fix: bootstrap provisions `nros setup fvp-aemv8r-smp --rmw
   cyclonedds` (cyclonedds prebuilt 0.10.5-nros1 + cyclonedds-src fork
   `8601ca66a` + rosidl).
3. **"board facts NOT delivered … no nano-ros checkout found"** — `nros
   ws board-facts` resolves the nano-ros checkout via `--nano-ros-path`
   → `NROS_REPO_DIR` → walk-up; an app dir outside the nano-ros tree
   needs the env var. Fix: build.sh exports `NROS_REPO_DIR`. Residual
   (non-fatal): facts still not delivered — "no board descriptor claims
   `fvp-aemv8r-smp`", the same pre-bundle directory match as #1.
4. **`nros-cpp` E0599: no variant `BackendDynamic`** — the Zephyr
   EMBEDDED C++ cyclonedds lane composes cargo features without `alloc`
   (zephyr/CMakeLists.txt:387) while nros-cpp's error mapper
   hard-references the alloc-gated variant (phase-361 W3 un-gating,
   lib.rs claims no buildable config lacks it — embedded cyclonedds C++
   is the counterexample; native_sim's `,std` hides it upstream).
   UNFIXED at upstream HEAD. ASI carries the idempotent
   `scripts/patches/nros-cpp-embedded-alloc-patch.sh` (build.sh applies;
   self-retires on upstream fix). → UPSTREAM ISSUE CANDIDATE.
5. **Test programs: "PoseStamped.h: No such file", then unknown flat
   type names** — the pin dropped the flat idlc-name compat layer; the
   Zephyr module now emits standard idlc names (`<pkg>_msg_dds__X_`)
   under `cyclonedds-ts/_genroot/<pkg>/msg/`, kept PRIVATE to the
   descriptor libs, and the nros-cpp `Publisher<T>`/`Subscription<T>`
   templates are typed-FFI-only (need generated C++ types). Fix: tests
   migrated onto the dual-mode umbrella (`messages.hpp` aliases +
   sentinel `_desc` stubs; FixedSequence push_back for Trajectory);
   `_genroot` exposed to test builds for any remaining C-header use.
   Branch policy: nros-only, no new `ASI_USE_NANO_ROS` gates.
6. **`CAN_FILTER_DATA` undeclared (can_output_test)** — pre-existing
   Zephyr 3.7 migration gap on this branch (flag removed after 3.5;
   standard-ID data filter is `flags 0`). First surfaced now because the
   mode was rebuilt on 3.7 for the first time since the migration.
7. **Entry panic default changed upstream** (phase-366 M5/R2): absent
   `PANIC` now means `platform` (`k_panic()` on Zephyr) where embedded
   images used to halt; `nano_ros_add_executable` exposes no PANIC
   keyword. Accepted (loud fatal is right for the island); revisit if a
   halt-on-panic policy is wanted — needs the `nano_ros_entry` spelling.
8. **Kconfig knobs went live** (#316): `CONFIG_NROS_EXECUTOR_MAX_CBS`
   default 16→4 and now actually forwarded; environment wins over
   Kconfig, and build.sh's `NROS_MAX_PARAMETERS=256` /
   `NROS_EXECUTOR_MAX_CBS=16` / `NROS_SUBSCRIPTION_BUFFER_SIZE=16384`
   exports were confirmed still read at the pin.

9. **FVP runtime smoke: controller runs (timer loop prints "Control is
   skipped since input data is not ready") but CI phase-1 markers never
   appear** — "Starting Controller Node"/"Controller Node Started"/
   "Actuation Safety Island is Live" lived only in the retired
   `src/main.cpp` imperative boot; the generated Entry prints no ASI
   banner, so the marker greps were a latent main-branch artifact never
   re-validated on this branch. Fix: `controller_pkg::Controller`'s ctor
   now owns the markers (before/after base construction — a ctor throw
   ends boot before they print, which is the failure CI should catch).

10. **Test images: `nros::create_node failed: -7`
    (NROS_CPP_RET_NOT_INIT)** — the polling shim's lifecycle note still
    said "`nros::init` is called from main.cpp"; test images carry their
    own `main()` (no generated Entry, no `Board::run_components`), so
    since the pin nothing initialized the runtime. Fix: the shim Node
    ctor performs a one-time `nros::init()`; the full image's generated
    Entry still owns init there (the guard never fires — the shim Node
    is test-only).

11. **unit_test hang after "Timer stopped via Node request"** — the
    polling shim's `stop()` used `pthread_cancel` + join; Zephyr POSIX
    implements deferred cancellation only and the poll loop's `usleep`
    tick is not a cancellation point there, so the cancel never lands
    and the join blocks forever. Fix: cooperative `running_` flag — the
    loop polls it, `stop()` clears it and joins; `spin()` is idempotent
    while spinning. (First exposed now: the runtime phases were never
    re-run on this branch since the Zephyr 3.7 migration, same story as
    the CAN filter flag in #6.) Companion observation: seven `os: tid
    0x… is in use!` prints at cyclone participant creation — Zephyr
    POSIX thread-pool slot reuse noise; session comes up and runs;
    watch, not currently actioned.

Overlay conf cleaned in the same pass: stale `CONFIG_NROS_CODEGEN_TOOL`
devcontainer path dropped (`-D_NANO_ROS_CODEGEN_TOOL` wins) and the
pinned domain-ID literal removed (Kconfig defaults to `NROS_DOMAIN_ID`;
the tap conf still deliberately sets 2 — nano-ros phase-180 split-brain
rule).

Note for the next bump: `eace28852` sits mid-workstream on nano-ros #260
(a53 SMP bring-up — different board family; no interference observed on
the armv8r FVP lane).

## Acceptance
- All four upstream runtime targets build from ONE branch; zephyr targets on
  nano-ros, freertos targets unchanged (until W5).
- FVP tap demo end-to-end green on the modern nano-ros pin.
- No hand-glued Zephyr compile-context in the node pkg; Entry is
  `nano_ros_add_executable` one-liner shape.
- QoS depth audit recorded; heap bounded under real trajectory load.
