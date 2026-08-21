# Phase 4 — FreeRTOS targets onto nano-ros (retire the vendored CycloneDDS)

Status (2026-08-20): OPEN — planned. The Zephyr targets are fully on
nano-ros (phase-3, validated end-to-end incl. the tap demo); the two
FreeRTOS targets still build the LEGACY vendored `cyclonedds/` submodule
plus the raw `common/dds` + bespoke-Node path. This phase migrates them and
deletes the last owned middleware from the repo. Upstream half:
nano-ros phase-370 (freertos-posix board variant + first live
Cyclone-on-FreeRTOS cell), filed from this scoping.

## Findings that shaped the plan (survey 2026-08-20, pin eace28852)

- nano-ros `nros-platform-freertos` exists (FreeRTOS clock/threads/malloc,
  lwIP-only net with a stubbed multicast join, Cyclone compat shims); the
  Cyclone fork carries a real ddsrt freertos+lwip port and the FreeRTOS
  cmake lane self-provisions `WITH_FREERTOS+WITH_LWIP` — but NO cyclonedds
  cell has ever run pub/sub e2e (zenoh is the only live FreeRTOS backend
  upstream; the old cyclone fixtures were retired in nano-ros Phase 220.C).
- nano-ros phase-292 W4.a already scoped OUR posix-sim case and approved
  "go, small": a board-level variant (`nros-board-freertos-posix`), RMW =
  the existing host/posix Cyclone path verbatim → zero new RMW work.
- Nearest precedent for "RTOS threads + host Cyclone" is threadx-linux —
  currently broken upstream (nano-ros issue 0715, SEGV in
  `_tx_thread_timeout`). Expect that defect class here.
- S32Z2: the Zephyr S32Z board crate exists upstream, but NO FreeRTOS
  S32Z bundle, no Cortex-R52 FreeRTOS toolchain file, no NETC netif in
  nano-ros. Expensive; hardware-gated.

## W5.a — `freertos-posix` (DONE 2026-08-20)

Consumed nano-ros phase-370 W1–W3 (landed same day; both ASI-filed issues
0729/0730 fixed at the bump, retiring the phase-3 workarounds). ASI side:

- [x] nano-ros pin bumped to `b13241d41` (submodule + west.yml lockstep);
      Zephyr full mode re-verified green with zero carried patches.
- [x] `build.sh --platform freertos-posix` switched to workspace mode:
      root CMakeLists gains a `NANO_ROS_PLATFORM=freertos` branch
      (`nano_ros_workspace` over autoware_msgs + controller_pkg + a new
      `freertos_posix_entry` Entry pkg, `BOARD/DEPLOY freertos-posix`,
      LAUNCH default from the SAME `controller_bringup` as Zephyr — one
      bringup, two platforms). `[deploy.freertos-posix]` added to
      system.toml (kind embedded, no netstack — host kernel owns it).
      Kernel = nros-provisioned (`nros setup --source freertos-kernel`).
- [x] Legacy posix path retired: `actuation_module/freertos/`
      (CMake + `freertos_main.cpp` + local dds/config/helper headers)
      deleted; `build_cyclonedds_target_posix()` deleted.
- [x] Runtime verified: `actuation_posix_entry` boots — FreeRTOS
      scheduler up, boot markers, CAN mock initialized, controller task
      ticking its input-wait cadence over host CycloneDDS, clean bounded
      exit (`NROS_ENTRY_SPIN_MS`), rpath-clean (no LD_LIBRARY_PATH).
- [x] Closed-loop smoke vs the demo compose stack (2026-08-21): posix
      compose override up (`SAFETY_ISLAND_DDS_INTERFACE=<iface>`), entry
      joined domain 2 via the HOSTED env rungs
      (`ROS_DOMAIN_ID=2 CYCLONEDDS_URI=file://demo/cyclonedds.posix.xml`
      — no rebuild needed, the #206 hosted resolution chain), pose+goal
      seeded headless → `/control/trajectory_follower/control_cmd` back
      on domain 1 at ~6 Hz, island streaming (CAN mock saturating).
      OBSERVATION for the soak: ~6 Hz vs the FVP lane's ~19 Hz+ —
      profile the POSIX-port tick / poll-executor pacing before calling
      it a regression (legacy posix lane had no recorded rate baseline).
- [x] Rate profiling round 1 + the `[tiers]` RT model (2026-08-21, pin
      `9f0a387b9`). Measurement: island-native (domain 2) == bridged
      (domain 1) at ~12.4 Hz — bridge exonerated; 100–140 ms stalls
      against the 30 ms timer = single-threaded-executor contention
      (timer sharing the thread with 8.8 KiB trajectory deserialization).
      FIX IMPLEMENTED — RFC-0047 split: the control timer moved into its
      own callback group (`create_timer_in` in the vendored controller's
      nros seam, `CALLBACK_GROUPS control` on the Node pkg) bound by the
      bringup to a real-time tier (`[tiers.control]`, group_tiers; RAW
      per-platform priorities: freertos 7 of 10, zephyr 5, posix 80).
      Result: **12.4 → 19.0 Hz**, stall ceiling 140 → 80 ms — parity
      with the FVP lane's baseline. In the same pass the Zephyr entry
      moved to the canonical LAUNCH+BRINGUP spelling (`nano_ros_entry`,
      configure-time model resolution) and the committed
      `config/system_model.yaml` was deleted (upstream rule: SystemModels
      are build artifacts) — BOTH lanes now bake from the one authored
      bringup including the tier model. Zephyr revalidated: full 5-phase
      FVP CI green on the tiers + LAUNCH image.
- [x] Rate profiling rounds 2–3 (2026-08-21) — CORRECTED STORY. The
      first analysis (filed as nano-ros 0744, "raw blocking waits park
      the simulated kernel") was WRONG — port-signal masking and CPU
      pinning both falsified it; 0744 is closed wontfix. The truth: the
      launch-declared `ctrl_period=0.03` NEVER REACHED the node — a
      four-defect upstream chain (emitters gated launch-param seeding on
      param_services AND emitted it post-construction; the executor
      store needed pre-node init; ComponentNode read its own per-node
      store; the capability lowering fn was called from no path). The
      "80–140 ms stalls" were the compiled 0.15 s default's real ticks.
      Fixed upstream as **nano-ros issue 0745** (emitter seeding
      pre-construction + lazy store + seed adoption + wired lowering;
      pin `93c0956ae`); ASI opts in via
      `[system].features = ["param_services"]`,
      `nano_ros_workspace(SYSTEM controller_bringup)`, and the Zephyr
      lane's `-DNANO_ROS_FEATURES` mirror. Instrumented result:
      standalone control timer **158.8 ms → 31.6 ms mean** (min 31.4 /
      max 32.5, n=1265). Both lanes revalidated (freertos-posix build +
      boot; full 5-phase FVP CI green — the FVP controller also runs at
      the true 30 ms for the first time).
- [x] 0745 follow-ups (2026-08-21, pin `6fb8579dd`): bool launch params
      now ctor-adoptable (upstream `nros_cpp_get_param_bool` + the
      adoption's bool arm); `control_output` now READ FROM THE SEEDED
      PARAM (`output_mode_from_name` with compile-time fallback —
      verified: the bringup's DDS_ONLY drives the node where the
      compiled DDS_AND_CAN used to); the freertos CI marker now asserts
      the seeded mode end-to-end (CAN stays covered by the Zephyr
      can-output-test phase).
- [x] Timer over-credit under load — filed as **nano-ros issue 0746**,
      CLOSED wontfix 2026-08-21: **executor exonerated, the ~50 Hz was
      `ros2 topic hz` aggregating stale duplicate island processes** on
      the shared domain (three old `actuation_posix_entry` instances
      found alive; min~0 bursts + max≈period is the multi-publisher
      signature; the round-1 "12.4 Hz vs 6.3 Hz effective" datum is
      exactly 2×6.3 — same artifact). Instrumented upstream spin/timer
      accounting: per-spin credit == tick clock to the microsecond,
      standalone AND under the full planner graph; single-process
      measurement under load: timer fires 31.7 Hz, wire 31.669 Hz avg,
      min 31 / max 32 ms, std dev 0.06 ms. The 31.6-vs-30 ms offset is
      the FreeRTOS POSIX port tick thread's usleep overshoot (~5.2 %,
      simulator-only; absent on FVP/hardware). Soak unblocked.
      RULE for all future rate measurements: prove the publisher count
      first (`pgrep -a actuation_posix_entry` / `ros2 topic info -v`).
- [x] Control-rate soak (2026-08-21): single island vs the demo compose
      planner (posix override, domain 2, bridge relaying domain 1),
      5-minute `ros2 topic hz --window 10000` on
      `/control/trajectory_follower/control_cmd`: **31.672 Hz average
      over 9633 samples, min 31 ms / max 32 ms, std dev 0.06 ms** —
      flat at the 30 ms tier period plus the posix-sim tick skew, no
      drift, no bursts, no stalls. The freertos-posix lane's control
      cadence question (6 Hz → 12.4 Hz → "50 Hz" across rounds 1–3) is
      closed: every anomaly was either the unseeded 0.15 s default
      period (#0745) or multi-process hz contamination (#0746).
- [x] **Autonomous DRIVING demo, Zephyr FVP island (2026-08-22)** — the
      full Autoware + Zephyr ASI stack drives the planning-sim vehicle
      to a goal, three missions completed (map-derived on-lane seeds,
      ~60 m / 28 m / 14 m; arrival within 0.21 m / 0.00 m of goal),
      rviz observing on the host X display. Every prior "closed loop"
      on this branch had verified only the emergency/stopped path.
      Chain of defects found and fixed to get here, in order:
      1. **nano-ros issue 0749** (fixed upstream, pin `d1c5b3b3b`): the
         Zephyr lane's curated cargo env dropped 5 of 6 executor sizing
         knobs — every Zephyr image silently built 1024-byte
         subscription buffers, so real 13.4 KiB trajectories were
         reassembled + ACKed by cyclone and DISCARDED with zero
         diagnostics (tshark ACKNACK analysis pinned it). Small
         degenerate stopped-trajectories fit 1 KiB, which is how the
         defect hid behind every green marker. Follow-up open upstream:
         fail-loud at the BUFFER_TOO_SMALL drop site.
         Consumer side: `NROS_MAX_PARAMETERS` pinned back to 32 in
         build.sh — 256 HANGS Zephyr boot right after
         dds_create_participant (bisected; upstream follow-up), and
         `NROS_EXECUTOR_ARENA_SIZE` capped at 448 KiB (derived ~1 MB).
      2. **No wall-clock epoch**: the island stamped commands from its
         boot epoch, and Autoware's vehicle_cmd_gate/monitors reject
         stale stamps — autonomous mode could never actuate. Fixed:
         `CONFIG_SNTP_SERVER_ADDRESS` Kconfig (tap conf points at
         192.168.10.1:12123) + `scripts/sntp-server.py` (unprivileged
         RFC-4330 responder on the tap host).
      3. **FVP pacing**: the baked board.cmake args free-run the model
         when idle (island clock raced 8-14x real → cyclone leases
         expired island-side, dropping live peers) and appended
         ARMFVP_EXTRA_FLAGS cannot override them (first-occurrence
         wins); the rate limiter lives in the VISUALISATION component,
         so headless FVP cannot pace at all. Demo runs FVP directly
         with `disable_visualisation=0 rate_limit-enable=1` (window on
         the host display; pacing measured 1.05x real).
      4. **Compute reality**: full MPC+PID on FVP takes ~160 ms per
         tick (~6 Hz island-side, ~4.7 Hz after bridge) — below the
         stock 5 Hz topic-monitor warn threshold, so
         `demo/component_state_monitor_topics.yaml` (compose-mounted
         override) relaxes the two control-command rate checks to
         2 Hz warn / 0.5 Hz error. Hardware islands run the true 30 ms
         tier and do not need it.
      5. **Duplicate-instance hygiene** (the #0746 lesson twice over):
         an orphaned FVP survived pid-file kills and ran concurrently
         (same IP/MAC on tap0 — ACKNACK storms, ghost SPDP peers,
         selective delivery), and the demo visualizer + a host rviz
         both named `rviz2` trip duplicated_node_checker, which blocks
         autonomous mode. Rate/engage debugging is invalid until
         `ps -eo pid,comm | grep FVP` and the node list are clean.
      Also: feedback-driven demo seeding landed in both demo scripts
      (pose accepted ⇔ kinematic_state publishes; goal accepted ⇔
      trajectory streams — blind seeds were silently lost on cold
      containers), and `scripts/run-posix-demo.sh` is the new
      one-command posix campaign (stale-island guard built in).

### W5.a wall ledger (all consumer-side unless noted)

1. `nros sync` requires `nros-launch-resolve` BESIDE the nros binary —
   built from `packages/cli/nros-launch-resolve` + symlinked
   (bootstrap-asi.sh now does both).
2. sync's internal cmake probes resolve the codegen tool from PATH, not
   from our `-D` — build.sh puts the CLI dir on PATH for the lane.
3. `nano_ros_workspace(ORDER_FROM_DEPENDS)` requires a package.xml per
   SUBDIR — added one to the `autoware_msgs` aggregation pkg.
4. Canonical `nros_generate_interfaces` wires INSTALL(EXPORT) an in-app
   aggregation never populates — `SKIP_INSTALL`, gated to the workspace
   lane (the Zephyr module variant doesn't parse the flag).
5. Workspace codegen is BUILD-time: the component must link the
   per-package `<pkg>__nano_ros_cpp` targets (include dirs + generation
   edge); the Zephyr lane's configure-time glob sees empty dirs there.
6. Platform dispatch: component defines `PLATFORM_FREERTOS` (PUBLIC —
   the generated entry TU compiles the same headers), `PLATFORM_ZEPHYR`
   stays on the Zephyr lane.
7. `platform_config.h` wants the legacy Kconfig-mirror
   `freertos_config_generated.h` — configure_file'd in controller_pkg's
   workspace branch (legacy defaults; DDS knobs inert, nano-ros owns
   transport; DDS_AND_CAN keeps the mock CAN path exercised).
8. Shim `usleep` needs explicit `<unistd.h>` on host (transitive on
   Zephyr).
9. Filed as **nano-ros issue 0740** (Makefiles can't see the
   cross-directory custom-command OUTPUT behind the entry TU's
   OBJECT_DEPENDS on nros-c's mirrored `nros_config_generated.h`) —
   FIXED upstream same day; the build.sh pre-build workaround is
   retired at the `9f0a387b9` pin (clean-build verified without it).
10. Component include dirs must be PUBLIC for the generated entry TU
    (zephyr lane hand-fed `app` instead).
11. Self-provisioned CycloneDDS emits shared `libddsc` into
    `<build>/lib` — `CMAKE_BUILD_RPATH` bakes the run path.

Acceptance: `./build.sh --platform freertos-posix` builds with no vendored
cyclonedds involvement; controller smoke passes on the simulator; the
legacy DDS wrapper is gone from the FreeRTOS-POSIX path.

### Deletion map (inventoried 2026-08-20; delete-when-replaced)

Died with W5.a (POSIX path) — DONE 2026-08-20:
- `build.sh` `build_cyclonedds_target_posix()` and the legacy
  `build_freertos_posix()` body (now the nano-ros workspace lane).
  `build_cyclonedds_host()` SURVIVES until W5.b (s32z2 host tools).
- `actuation_module/freertos/` — deleted whole (CMake, `freertos_main.cpp`,
  local dds/config/helper headers).

Dies with W5.b (correction to the original map: these serve the s32z2
legacy build via node.hpp's `#else` side, so they outlive W5.a):
- `actuation_module/include/common/dds/` (raw-CycloneDDS wrapper).
- Dual-mode `#else` (legacy) sides: `common/node/node.hpp` (bespoke
  `Node` + param variant), `common/clock/clock.hpp` (idlc `Time.h` side),
  `autoware_msgs/messages.hpp` (idlc include block + flat aliases +
  legacy `TrajectoryMsg` borrow-wrapper),
  `autoware_trajectory_follower_node/controller_node.{hpp,cpp}` (the
  raw-DDS constructor/body halves), `common/net/network_config.*` legacy
  branches. Branch policy applies: nros-only, gates removed not extended.

Dies with W5.b (S32Z2):
- `build.sh` `build_freertos_s32z2()` legacy body +
  `actuation_module/freertos_s32z2/scripts/build-cdds-target.sh` +
  `cmake/arm-cortex-r52.cmake` hand toolchain (superseded by the board
  bundle's), NETC glue split per licensing.
- `cyclonedds/` submodule + `.gitmodules` entry + its
  `autowarefoundation/cyclonedds` `freertos-s32z2` fork branch — the
  final removal, once nothing references it.

Open decision (W5.a): FreeRTOS kernel provenance — ASI's `freertos-kernel/`
submodule vs nano-ros-provisioned `third-party/freertos/kernel`
(`nros setup --source freertos-kernel`). Default: consume nano-ros's
(one SSOT, index-pinned), keep ASI's submodule only if the S32Z2 RTD
integration needs a specific kernel rev; decide when wiring W5.a.

Baseline (pre-migration reference, verified 2026-08-20 on this branch at
the phase-3 endpoint): legacy `freertos-posix` builds green
(`./build.sh --platform freertos-posix -d build/freertos-posix` →
`actuation_freertos`) and boots — FreeRTOS sim scheduler up, controller
node starts, DDS participant created on domain 2. The phase-3 changes to
shared headers (messages.hpp umbrella, clock, tests) did not disturb the
legacy side. Smoke recipe: `docs/user_guide/freertos_posix.rst`.

## W5.b — `freertos-s32z2` (STARTED 2026-08-21; hardware-gated)

Upstream prerequisites moved: nano-ros phase-370 W4 LANDED (the embedded
Cyclone×FreeRTOS cell on QEMU MPS2 builds, boots and creates
writers/readers — five more seam defects fixed, incl. a ddsrt-lwIP
per-thread netconn semaphore fix on the fork and the `.init_array`
descriptor-registration pattern, issue 0733). The upstream half of W5.b
is now **nano-ros phase-372** (filed 2026-08-21 from this side): Cortex-R52
cross profile, `nros-board-s32z270-freertos` bundle, a strong-symbol
netif seam so the NXP-licensed NETC glue stays in ASI, Cyclone/lwIP
hardening on the QEMU cell before hardware.

- [x] Upstream: `nros-board-s32z270-freertos` bundle scoped and filed
      (nano-ros phase-372, 2026-08-21).
- [ ] ASI: replace `freertos_s32z2/scripts/build-cdds-target.sh` + the
      hand toolchain with the board-bundle consumption; NETC glue moves
      behind the board crate where generic, stays in ASI where
      NXP-RTD-licensed.
- [ ] Retire the vendored `cyclonedds/` submodule and its
      `freertos-s32z2` fork branch for good.

Acceptance: S32Z2 image builds via nano-ros; on-target smoke on the
board; `cyclonedds/` gone from `.gitmodules`.

## Non-goals

- New RMW backends on FreeRTOS (cyclonedds only — it is what the Autoware
  side speaks).
- Zephyr-side changes (done in phase-3).
