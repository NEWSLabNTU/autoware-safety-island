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
- [x] **Driving re-baseline at pin `14e484fe0` (2026-08-24)** — after
      the 0756 unpin (256 param slots: MPC weights past the 32nd now
      real) and the #736 tier-timer chain:
      * Control-cmd rate, post-bridge: **~9.7 Hz during MPC driving**
        (was ~4.7 Hz on 2026-08-22 — ≈2x; max inter-cmd gap 0.29 s
        around state transitions) and 29–38 Hz on the stopped/e-stop
        fast path (was ~19 Hz+). Single-publisher verified before
        every rate read (the 0746 rule).
      * Autonomous mission re-demonstrated: 12.5 m drive, clean stop.
        Island parks when the planner's approach-creep target
        (~0.4 m/s) drops below its departure threshold — stopped
        5.5 m short of goal; controller conservatism, not a fault.
      * Seeding facts, learned the hard way: the runbook seed pair in
        `run-tap-demo.sh` produces the E-STOP loop only (its goal
        snaps to a crossing lane → the planner emits a goal-anchored
        11-point zero-velocity sliver; the island correctly refuses —
        "too large position error"). A DRIVING pair must be
        lane-consistent: spawn on a lane point with the LANE's
        heading, goal probed along the lane via ADAPI
        `set_route_points` until it accepts (works: spawn
        x 3714.44 y 73753.15 ori z 0.25 w 0.968 → goal x 3730.2
        y 73761.8). Bare `/planning/mission_planning/goal` publishes
        leave ADAPI route_state UNSET, which reds
        `component_state_diagnostics: route_state` and blocks
        autonomous — route via ADAPI, not the bare topic.
      * **Post-arrival runaway — ATTRIBUTION CORRECTED 2026-08-24.**
        First written up here as an island NaN defect ("the island's
        longitudinal path drove the vehicle to its 50 m/s clamp").
        That was WRONG, and an instrumented re-run
        (`/api/fail_safe/mrm_state` + hazard_status + both command
        topics + odometry on one timeline) shows the real chain, all
        of it HOST-side:
          1. island drives the mission and stops at the goal — its
             command equals the gate's output sample-for-sample the
             whole way (max 2.22 m/s / +0.57 m/s²);
          2. on arrival the PLANNER stops publishing
             `/planning/scenario_planning/trajectory` (frozen at 248
             samples in the capture);
          3. `/autoware/planning/topic_rate_check/trajectory` goes
             ERROR ⇒ hazard level 3, emergency;
          4. MRM engages (`mrm_state` 1→2→3, behavior 2) and
             `mrm_emergency_stop_operator` publishes a DIVERGING
             command on `/system/emergency/control_cmd` — velocity
             climbing through 5×10⁵ m/s with acceleration ~+1.9×10³,
             i.e. its ramp integrates the wrong way;
          5. `vehicle_cmd_gate` takes the emergency source (it
             outranks the island), clamps to its own limits — 25 m/s,
             +4 m/s² — and the simulator integrates to its 50 m/s
             clamp.
        Throughout step 5 the island keeps commanding 0.0 m/s at
        −2.5 m/s². The island was never in the runaway loop; this is
        an Autoware-side MRM defect in the demo image, and the
        island-side lesson is only that a stopped island must keep
        SAYING stop (below).
      * **Island hardening landed anyway (justified on its own).**
        The NaN was real even though the runaway was not ours: after
        arrival the island re-processed the planner's degenerate
        last trajectory forever, `calcLongitudinalOffsetToSegment`
        spamming NaN until reboot. Three changes, verified against
        the reproduced event (zero NaN lines, island held 0.0/−2.5
        for the whole emergency):
          1. NaN-safe threshold spellings — `!(dev <= limit)` instead
             of `limit < dev` in the PID deviation guard and the MPC
             position/yaw guards, so a NaN error routes to EMERGENCY
             instead of slipping past a comparison that is false for
             NaN;
          2. trajectory FRESHNESS: a trajectory older than
             `timeout_thr_sec` is not ready, so a silent planner can
             no longer keep the island tracking a stale sliver;
          3. **silence is not safe** — when inputs are missing or
             stale, or a computed command is non-finite, the island
             now PUBLISHES an explicit safe stop (hold last measured
             steering, v=0, −2.5 m/s²) every cycle instead of
             returning without publishing. The old behaviour left
             whatever it last emitted latched downstream, which is
             the one way an island can cause a runaway.
      * Hygiene reconfirmed (the item-5 lesson): a 3-day-old
        `asi-rviz` container tripped duplicated_node_checker and
        blocked autonomous until stopped; `service_log_checker` then
        stays latched red with the failure history (cosmetic, but
        confusing — it records every refused mode change). Same trap
        bites DEBUG PROBES: two `rclpy` probe nodes sharing a name
        (mine, left running) reproduce the identical block, and
        `pkill` from the host does not reach them — kill inside the
        container's PID namespace (`docker exec … kill`).
- [x] **`scripts/run-tap-demo.sh --drive` — the driving mission is now
      one command (2026-08-24).** The pre-existing seed path only ever
      exercised the emergency-stop loop; `--drive` does the three
      things a driving mission actually needs (lane-consistent spawn,
      route via ADAPI `set_route_points` rather than the bare goal
      topic, and `change_to_stop` the moment the mission ends, before
      the planner goes quiet and the host MRM defect fires). Verified
      end-to-end at pin `14e484fe0` with the safety fix in: island
      drives the route, tracks it (lateral offset 0.25 m → 0.00 m),
      peaks 2.14 m/s, stops cleanly. Post-mission control-cmd rate
      6.7 Hz measured with the mission finished (the ~9.7 Hz figure
      above is mid-drive).
      **Parking ~5 m short of the requested goal was NOT an island
      fault, and is now GONE** — an instrumented probe (ego pose +
      nearest trajectory index + arc distance to the first
      zero-velocity point + island command, 2 Hz) showed the planner
      zeroing its trajectory velocity 0.26 m ahead while the requested
      goal was 5.35 m further, with the island's departure check
      correctly refusing to move for a stop point inside 0.5 m. The
      first reading of that was "the smoother keeps a stop margin
      before the goal". The map-derived mission (below) disproves it:
      with a goal ON the lane centerline the same stack routes all the
      way and the vehicle ARRIVES. The 5 m was the distance between a
      hand-picked goal and the nearest pose the planner could actually
      route to — an artifact of the goal, not a margin.

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
- [x] Exploration pass (2026-08-22): full gap analysis recorded in
      nano-ros phase-372 "Exploration findings". Load-bearing facts:
      the netif strong-symbol seam already exists upstream
      (`nros_board_register_netif`/`_poll_netif` — ASI's `ethif_shim.c`
      becomes a strong override, not a new seam); the Cortex-R52 GIC
      kernel port is NXP-licensed AND needs ASI's `port.c.patch`
      (Thumb-resume CPSR bug), so the kernel is consumer-provisioned via
      `FREERTOS_DIR`/`FREERTOS_PORT` like the posix lane; upstream
      multicast join is stubbed (`nros-platform-freertos/src/net.c`) —
      the first blocker Cyclone SPDP hits; the hardware-proven seeds
      (FreeRTOSConfig/lwipopts, 4 linker fragments incl. the
      non-cacheable NETC BD region, cp15/board_init) are enumerated for
      the bundle.

ASI-side work breakdown (ordered; 1-3 can start before hardware):

1. [x] Upstream phase-372 W1-W4 LANDED (2026-08-22, pin `d03ea3e48`):
       Cortex-R52 cross profile (armv8r-none-eabihf + cc-rs FPU env
       class fix), `nros-board-s32z270-freertos` bundle + cmake overlay
       (env-provisioned kernel, `GCC/ARM_CRx_No_GIC` link-default),
       weak fail-loud netif/tick hooks, `[arch.cortex-r52]` profile,
       emitter allowlist. ACCEPTANCE: the C++ cyclonedds workspace cell
       cross-links for ARMv8-R from a clean checkout (fixture witness
       `workspace-cpp-s32z270-freertos`); MPS2 sibling re-verified
       (builds, boots, SPDP multicast egress on QEMU). The W4 multicast
       worry was stale: LWIP_IGMP has been on family-wide; RX-side
       interop + heap-under-graph tests are hardware/tap-gated in W5.
2. [x] `system.toml`: `[deploy.s32z2]` added (kind embedded, board
       `s32z270-freertos`); entry leaf
       `src/freertos_s32z2_entry/` (`nano_ros_add_executable`, TYPED,
       DEPLOY `s32z270-freertos`). (2026-08-22)
3. [x] build.sh: `freertos-s32z2` IS the nros workspace lane (legacy
       vendored-CycloneDDS lane renamed `freertos-s32z2-legacy`).
       Mirrors `build_freertos_posix()`: nros sync + workspace cmake
       with the upstream `arm-freertos-armcr52` toolchain; kernel is
       env-provisioned (`FREERTOS_DIR`/`FREERTOS_PORT`, default =
       nros-pinned kernel + `GCC/ARM_CRx_No_GIC` for the link-complete
       image; `scripts/provision-nxp-freertos.sh` stages the patched
       NXP `GCC/ARM_CR52_GIC` copy — port.c.patch applied — and prints
       the overrides). SDK-provisioned arm-none-eabi-gcc 13.2 preferred
       over system 10.3 (10.3 rejects the entry codegen's C++
       designated initializers). (2026-08-22)
4. [x] Licensed glue seam authored (pre-hardware half): new pkg
       `src/s32z2_board_glue/` carries the STRONG
       `nros_board_register_netif`/`_poll_netif` overrides delegating
       to the proven legacy `lwip_bringup.c`; env-gated on
       `S32_RTD_PATH` — unset ⇒ pkg contributes nothing and the image
       link-completes on the bundle's weak fail-loud stubs (verified).
       Cross-only remedies carried into the workspace: Eigen psincos
       ILP32 configure-time patch, FreeRTOS-backed pthread shim
       (staged ALONE so the legacy FreeRTOSConfig.h cannot shadow the
       bundle's; newlib-13.2 `_POSIX_THREADS` typedef fallback; task
       creators keyed `ASI_S32Z2_NXP_PORT` ⇔ `xTaskCreate*Fpu`, static
       path gated on `configSUPPORT_STATIC_ALLOCATION`). RTD source
       wiring into the glue target = first task of the hardware
       session (item 5). ACCEPTANCE MET 2026-08-22:
       `./build.sh --platform freertos-s32z2` links
       `actuation_s32z2_entry` from clean checkout, Tag_CPU_arch v8-R,
       code at 0x31800000, `.bss` NOLOAD segment (loader-fix layout).
5. [ ] Hardware smoke (gated on board access): boot-parity with the
       legacy lane's proven baseline (scheduler + NETC RX/TX + Cyclone
       domain-2 participant + controller live), then the 30 ms tier +
       launch-seeded params (0745 chain) — the legacy lane ran 150 ms
       compiled defaults.
6. [ ] Retire the legacy lane = phase-5 W3 (whole `freertos_s32z2/`
       legacy set, `cyclonedds/` submodule + fork branch, `msg/*.idl`,
       idlc CMake branch, dual-mode gates W4) in one commit.

Acceptance: S32Z2 image builds via nano-ros from a clean checkout with
only NXP-licensed pieces provisioned locally; on-target smoke parity
with the legacy baseline; `cyclonedds/` gone from `.gitmodules`.

## MRM divergence — investigated and root-caused (2026-08-24)

The post-arrival runaway (see the driving re-baseline above) was traced to
`mrm_emergency_stop_operator` publishing an ACCELERATING command. This is
the measurement record; the chain has two independent halves, one theirs
and one ours.

**Measured, not inferred.** All numbers below come from the live demo:
`ros2 param get` on the operator, `ros2 node info` for its wiring, and an
rclpy probe sampling `/system/emergency/control_cmd` and
`/control/command/control_cmd` at full rate across the engagement edge.

1. **It is NOT a feedback loop.** The operator subscribes to the gate's
   output (`/control/command/control_cmd`) and publishes the emergency
   command the gate then selects, so a loop is available — but driving it
   via its own service (`/system/mrm/emergency_stop/operate`) with the gate
   NOT in emergency reproduces the divergence exactly: over 40 s the
   emergency command reached v = 138 497 m/s, a = +3786 m/s² while the
   gate's own output sat unchanged at 0.0 / −1.5. The divergence is
   internal to the operator.
2. **The ramp itself is correct.** Sampled `da/dt = −3.000` exactly
   (= `target_jerk`), and `dv/dt` equals the current acceleration, i.e.
   `a_{k+1} = a_k + jerk·dt`, `v_{k+1} = v_k + a_k·dt` at
   `update_rate = 30`. Parameters are sane: `target_acceleration = −3.0`,
   `target_jerk = −3.0`.
3. **The SEED is the defect.** Capturing the engagement edge shows the
   published stamp jump BACKWARD by 2376 s at the transition, and the first
   operating sample carrying `a₀ = +7127.39`, `v₀ = 3564.44` — exactly
   `a₀ = −1.5 + 3.0 × 2376` and `v₀ = a₀ × 0.5`. So the operator seeds its
   first ramp step over `dt = (its own now) − (the input command's stamp)`
   with no sanity clamp, and applies the jerk term with the sign that turns
   a braking ramp into `+|jerk|·dt`. A single mis-stamped input therefore
   converts an emergency STOP into maximum acceleration, and the ramp needs
   ~40 min to unwind. Upstream Autoware robustness bug (this demo image);
   we cannot fix it from here, and `--drive` avoids it by leaving
   autonomous mode as soon as the mission ends.
4. **Our half: the island's clock races on FVP.** The 2376 s is not
   arbitrary — it is the offset between the island's stamps and host wall
   time. Measured live: island stamp 1787579546 vs host 1787575852
   (offset 3694 s), growing 160 s per 16 s of wall clock, i.e. the island's
   wall-clock estimate advances ~10.5× real time WHILE IDLE. Cause is the
   known FVP pacing artifact (phase-3 item 3: the model fast-forwards when
   the guest is idle; the rate limiter lives in the visualisation
   component and does not pace idle time). The island seeds its epoch from
   SNTP exactly ONCE, in the boot network hook
   (`board_network_hook.cpp` → `Clock::init_clock_via_sntp()`), and then
   advances it with the FVP-fast tick — so the error accumulates without
   bound for as long as the image runs.

**Why the two halves met.** The island goes idle exactly when the planner
stops publishing at goal arrival; that is also the moment Autoware's
trajectory rate check errors and MRM engages. So the operator's first
ramp step lands precisely when the island's stamps are furthest into the
future — worst input at the worst moment.

Follow-ups from this (tracked in "Remaining work" below): periodic SNTP
re-sync/slew on the island side, and the same requirement added to the
nano-ros platform epoch design (issue 0758) so every consumer inherits a
bounded stamp error rather than a one-shot epoch.

## Remaining work and follow-ups (as of 2026-08-24)

Consolidated so nothing lives only in a commit message. Phase-5 carries
the legacy-retirement detail; this is the whole open set.

**Hardware-gated (nothing else blocks them):**
- W5.b item 5 — on-target smoke: wire the NXP RTD NETC sources + PBcfg into
  `src/s32z2_board_glue` (the package is authored and env-gated; only the
  source list is deliberately unwritten), run
  `scripts/provision-nxp-freertos.sh` for the patched CR52_GIC port, reach
  boot parity with the legacy baseline, then the 30 ms tier + launch-seeded
  params.
- W5.b item 6 = phase-5 W3/W4 — retire the legacy lane in one commit
  (`actuation_module/freertos_s32z2/`, the `cyclonedds/` submodule + fork
  branch, `msg/*.idl`, the idlc CMake branch), then collapse the
  `ASI_USE_NANO_ROS` gates in the 8 remaining dual-mode files and delete
  `include/common/dds/`.

**Island clock (from the MRM investigation):**
- [x] Periodic SNTP re-sync instead of the one-shot boot epoch — LANDED
      2026-08-25. `src/common/clock/clock_resync.cpp` runs a dedicated
      lowest-priority thread (never a timer callback or a work item:
      `sntp_simple()` blocks, and must not do so on the executor thread
      that carries the control tier), interval
      `CONFIG_ASI_SNTP_RESYNC_INTERVAL_S` (default 10 s, 0 restores the
      old behaviour). It sleeps in KERNEL time on purpose, so a racing
      guest clock re-syncs more often in real time. Corrections ≥ 0.25 s
      are logged, so drift is visible instead of silent.
      MEASURED on the tap demo: the thread steps the clock by −9.08 s
      every cycle and the island-vs-host offset now oscillates 3–8 s,
      against 3694 s and growing before. Bounded, which is the whole
      claim — it does not make the peer's unclamped `now − stamp` safe.
- [x] Same requirement filed upstream on nano-ros issue 0758: the epoch
      hook must be RE-callable with a deploy-fact interval, not a
      one-shot (amended 2026-08-24, commit `bdbbe3cfd`).

**Upstream (nano-ros) — filed, waiting:**
- 0754 idlc rung ignores the handed codegen tool; 0755 board-facts DEPLOY
  passthrough; 0758 platform epoch source. (0753/0756/0757 are resolved.)

**Upstream (Autoware) — recorded, not filed:**
- `mrm_emergency_stop_operator` seeds its ramp from an unclamped
  `now − input.stamp` with an inverted jerk sign (detail above). Not our
  repo; documented here and in `scripts/run-tap-demo.sh` so the next
  person does not re-chase it.

**Phase-5 W5 (ASI plumbing → nano-ros features):**
- [ ] `common/logger/` → `nros_log`: sequenced BEHIND W3 because the legacy
      lane compiles `logger.hpp` and links no nros; a swap now would need a
      banned mode gate. Keep the `log_*` API surface (20+ vendored Autoware
      TUs call it), swap the sink; upstream has no throttle macros yet, so
      `log_*_throttle` stays ASI-side.
- (poll shim, network_config, main.cpp, SNTP epoch: closed or filed above.)

**Demo / tooling:**
- [x] Lanes verified at pin `957c2b3ed` (2026-08-25): zephyr FVP 5-phase
      CI, freertos-posix CI and the freertos-s32z2 link are all green on
      the unmodified tree. NOTE upstream main has since moved ~40 commits
      past that pin; bumping is a separate decision (the parallel session
      that set it owns the sweep for the next one).
- [x] `--drive` mission is DERIVED from the map (2026-08-25) —
      `demo/derive-drive-goals.py` runs inside the Autoware container
      (lanelet2 python bindings), snaps a hint point onto the nearest
      road centerline, and walks the routing graph to emit a spawn pose
      plus goal candidates at requested ARC lengths. The MGRS square
      origin is computed from the grid code (the python bindings expose
      no MGRS projector, so the map loads under a UTM projector anchored
      at one of its own nodes and is translated into the square — same
      zone, so a pure translation). Hand-probed poses remain only as a
      fallback. VERIFIED: derived spawn matches the old hand-probed one
      to 0.01 m, and a 30 m derived mission reached `route_state=3`
      (ARRIVED) 0.12 m from the goal — the first arrival this demo has
      recorded.
- [ ] The FVP idle fast-forward has no clean pacing knob; the visualisation
      rate limiter does not cover idle. Worth a look if demo timing
      fidelity ever matters beyond the clock issue above.

## Non-goals

- New RMW backends on FreeRTOS (cyclonedds only — it is what the Autoware
  side speaks).
- Zephyr-side changes (done in phase-3).
