# Phase 7 — real-time evaluation of the Zephyr FVP lane

Status: **in progress** (started 2026-08-21). Scope: measure the scheduling
behaviour of the safety island on its production target, and build the tooling
that makes those measurements repeatable. Distinct from phase 4's rate
profiling, which was FreeRTOS-POSIX-side and host-measured; this track is
target-side, on `fvp_baser_aemv8r`.

Survey date: 2026-08-25. Legend: [x] done, [ ] planned, [~] deliberately
deferred (with the condition that unblocks it).

Renumbered from 6 to 7 on 2026-08-26: phase 6 is the emulated Cortex-R52 lane
(`phase-6-emulated-r52-lane.md`), which has an upstream counterpart in nano-ros
phase-385. This track had taken the number first by a day, but the migration
sequence is not mine to allocate from.

Design reference: `docs/design/rt_evaluation_zephyr.rst` — mechanism survey,
measured results, and the caveats that bound each. Upstream defects found on
the way: `docs/design/upstream-zephyr-issues.md`.

## W10 — the duplicate setTrajectory  [x] FIXED 2026-08-28

`MpcLateralController::isReady()` and `::run()` each called
`setTrajectory(input_data.current_trajectory, input_data.current_odometry)`
with identical arguments, one immediately after the other — the node calls
`isReady(*input_data)` then `run(*input_data)` on the same object. So the most
expensive operation in the cycle (resample, filter, curvature) ran TWICE per
commanded cycle, and the trajectory was pushed into `m_trajectory_buffer`
twice, which is the buffer the shape-change detection reads.

Removed from `run()`, not from `isReady()`. Removing it from `isReady()`
deadlocks: that function's own `m_reference_trajectory.empty()` check is
satisfied by the call, so it would return false forever and `run()` would
never be reached to populate it.

Measured, same workload:

| phase | before | after | delta |
|---|---|---|---|
| `mpc_lateral` | 298.1 ms | **227.5 ms** | −70.6 |
| `in:is_ready` | 33.95 ms | 21.85 ms | −12.1 |
| cycle total | ~340 ms | **~254 ms** | −86 (~25 %) |
| period p90 | 374 ms | 298 ms | −76 |

The prediction was ~34 ms off `mpc_lateral` and no change to `is_ready`. Both
deltas came out LARGER, so the duplicate cost more than one redundant call —
most likely the doubled buffer pushes were themselves costing time in the
maintenance loop, and halving the churn helped both sites.

**It does not change the conclusion.** 227 ms is still 7.6x the 30 ms budget.
Worth fixing on its own merits — duplicated work and corrupted buffer
semantics — but the period question remains a controls decision.

## W8 — stack headroom is now a CI assertion  [x] 2026-08-27

Three stack overflows were found in this repo by reading the Layer 1 report by
eye, and none printed a diagnostic:

| thread | allocated | needed | how it presented |
|---|---|---|---|
| `net_socket_service` | 1200 | 2880 | silent corruption; fatal only once INIT_STACKS painted the stacks |
| `main` | 16 KiB | 153 KB | booted to "Live", then zero control cycles |
| `asi_sntp_resync` | 4096 | 7024 | reported 100 %, overflowing on every loaded run |

`require_stack_headroom` in ci-helpers.sh asserts no thread exceeds 85 % of its
allocation, wired into FVP CI phase 6 which already captures the report. 85 %
is chosen against the measured figures: the healthy image's worst thread sits
at 70 %, and a thread reporting 100 % is ALREADY overflowing — the analyzer
clamps at the stack end, so its true requirement is unknown and may be far
higher. Verified both directions against real logs: it catches the
`asi_sntp_resync` 4096/4096 breach and passes a healthy report.

The point is that this pattern recurred three times and each instance cost
hours of bisection. It is now caught without anyone looking.

## W1 — instrumentation  [x]

- [x] **Layer 1, scheduling statistics.** `./build.sh --trace-stats` +
      `actuation_module/tracing_stats.conf`. `SCHED_THREAD_USAGE_ANALYSIS`
      gives per-thread `longest` (worst contiguous slice) and dispatch counts
      on top of cycle totals. Measured non-regressive against a control: the
      DDS-loopback workload passes in 12.187 s either way.
- [x] **Emission.** `src/common/diag/thread_stats_report.c` — a
      self-registering `K_THREAD_DEFINE` with a start delay, because Zephyr's
      `CONFIG_THREAD_ANALYZER_AUTO` prints before its first sleep behind a
      zero-delay thread and its dump lands during boot. Report count is capped
      (`ASI_THREAD_STATS_MAX_REPORTS`): the FVP fast-forwards through WFI, so
      once the workload ends an uncapped reporter emitted 2000 blocks /
      104k lines in a 130 s run.
- [x] **Layer 2, CTF task timeline.** `./build.sh --trace` +
      `scripts/capture-fvp-trace.sh` (build → bounded run → decode).
      `CONFIG_TRACING_SYNC`, NOT async — see W4.
- [x] **Decoder.** `scripts/parse-zephyr-ctf.py`, standalone: reads the TSDL
      directly, no babeltrace2/`bt2` (which the FVP host lacks). Largest clean
      capture 6 545 980 events, 0 bytes skipped, 0 trailing.
- [x] **CI.** Phase 6 of `run-zephyr-fvp-ci.sh` asserts the statistics layer
      keeps the workload green and that the report appears. `forbid_marker()`
      added and applied to phases 1-4 as well — the runtime images are killed
      by timeout, so a crash does not change the exit code and a
      `require_marker`-only phase stays green straight through one. That is
      exactly how W2's stack overflow hid.

## W2 — defects found in this repo  [x]

- [x] **`net_socket_service` stack overflow** (fixed 2026-08-23,
      `prj_actuation.conf`). Needs 2896 bytes; Zephyr's default is 1200. Present
      in the SHIPPING image, not just diagnostic builds — the control build uses
      the same default and boots, so the overflow was already happening and
      merely silent, corrupting whatever sat adjacent. It only became visible
      once `CONFIG_INIT_STACKS` painted the stacks. Found by the Layer 1
      reporter on its first real run.
- [x] **Control tier outranked the DDS transport** (fixed 2026-08-24,
      `controller_bringup/system.toml`). `[tiers.control.zephyr] priority = 5`
      against nano-ros RFC-0079's Zephyr allocation — transport at band 7, tier
      pool [8, 14] — so the control tier could preempt the transport it depends
      on to receive trajectories and publish commands. Upstream closed the same
      violation in its own bringups (5 → 9); this consumer bringup had not
      followed. Now 9, verified as `9LL` in the generated entry and as a
      `thread_priority_set` event in a capture.

## W3 — findings that change how the lane is understood  [x]

- [x] **The tier model IS active**, and an earlier reading here said otherwise.
      nano-ros runs the BOOT tier on the calling thread and only chain-spawns
      the rest, so with one declared tier `control` runs on `main` and no
      tier-stack thread exists. Absence of tier threads is not absence of tiers.
- [x] **The executor wakes every 6.000 ms**, not every 30 ms (p50 6.0000,
      p90 6.0007, n=59635; zero inter-dispatch gaps in a 25-35 ms window).
      That is `spin_period_us = 5000` plus ~0.67 ms of work per wake — five
      wakes per control period. NOTE the trace cannot see callback boundaries,
      so this measures the executor's cadence, not the control callback's rate.
- [x] **No Zephyr kernel timer is involved.** Zero `timer_start` events with
      `CONFIG_TRACING_TIMER=y`; nano-ros paces its executor itself. The timer
      event family is therefore useless on this lane for separating a
      mis-armed period from a mis-delivered one.
- [x] **The FVP counter runs during WFI**, decoupled from the tick clock the
      console prints. A 12.214 s run accumulates ~2350 s of counter time,
      essentially all inside idle slices. The decoder therefore reports no
      wall-clock span and no CPU percentage, and bases totals on non-idle
      execution. Counts, ordering and structure were never affected.

## W4 — upstream Zephyr defects  [~]

Written up in `docs/design/upstream-zephyr-issues.md`;
`scripts/file-upstream-issues.sh` files them with `gh`. All four re-checked
against `zephyrproject-rtos/zephyr@main` on 2026-08-24 and still present; a
tracker search found no existing report for any of them.

- [x] **FILED 2026-08-27**: #117634 (async tracing bricks boot on USE_SWITCH),
      #117635 (CTF socket hooks deref unchecked), #117636
      (THREAD_ANALYZER_AUTO_STACK_SIZE 4096 vs a measured 9040), #117637
      (k_thread_priority_set emits no CTF event). Two drafts were corrected
      first: both had attributed crashes to the reported defect that later
      work traced elsewhere, so they now report what is established and say
      what is not.
- [x] Issue 1 — `CONFIG_TRACING_ASYNC` starts a kernel timer from inside the
      arm64 context switch; the image does not boot. Worked around with
      `CONFIG_TRACING_SYNC`, at the cost of tracing in the traced context.
- [x] Issue 2 — CTF socket hooks dereference their `sockaddr` unchecked.
      Worked around with `CONFIG_TRACING_NETWORKING=n`, which costs the
      DDS-path visibility the design doc originally advertised.
- [x] Issue 3 — `THREAD_ANALYZER_AUTO_STACK_SIZE` default of 4096 is far too
      small; the analyzer needs 9040 bytes here and overflows mid-walk.
- [x] Issue 4 — `k_thread_priority_set()` emitted no CTF event, broken in four
      places. FIXED LOCALLY as
      `patches/zephyr/0001-ctf-trace-k_thread_priority_set.patch`;
      `bootstrap-asi.sh` re-applies it after `nros setup board` rewrites
      `zephyr/`. This is the one that mattered most: an empty event stream is
      not neutral, it misleads by omission, and it is what produced the wrong
      W3 conclusion about the tier model.

## W5 — loaded measurement  [x] DONE 2026-08-27

**The capture exists.** An autonomous mission with the island in the loop: MPC
steering through the curve, PID accelerating and braking, peak 1.96 m/s,
stopped within 0.17 m of the goal. 140 MB / 11.6 M events, 0 bytes skipped.

```
period ms:   min=7.997  p50=32.000  p90=357.000  p99=422.998  max=4666.965  n=949
duration ms: min=1.125  p50= 1.373  p90=336.632  p99=402.980  max=4648.463  n=949
outcomes:    commanded=327  safe_stop=622
```

**327 `commanded` cycles** — MPC and PID executed under load for the first
time. Every earlier capture was 100 % safe-stop.

**CORRECTION (same day).** The block above is the first 140 MB of the capture
— boot plus the mission — and it is the BEST-BEHAVED stretch. Re-decoding the
settled 2.2 GB file, which covers sustained operation afterwards:

```
enter=7405  exit=7404
period ms:   min=7.996  p50=249.000  p90=254.000  p99=378.000  max=4666.965
duration ms: min=1.125  p50=238.095  p90=242.487  p99=358.788  max=4648.463
outcomes:    commanded=6006  safe_stop=1398
```

So it is NOT "a healthy 32 ms median with a bad tail". Sustained, the median
cycle is **249 ms** — the loop settles at ~4 Hz against a declared 30 ms
period. The 3.19 Hz the demo measured on the wire matches the SUSTAINED
figure, not the windowed one, which in hindsight was the clue.

The trim was verified to decode identically, but against the file as it stood
at that moment while the island was still running and the file still growing.
Comparing a prefix to a moving file is not the same as comparing it to the
finished one. Conclusions below that rest on the windowed p50 are qualified
accordingly.

**The finding is the TAIL.** Idle vs loaded, same build:

| | idle | loaded |
|---|---|---|
| period p50 | 31.000 ms | 32.000 ms |
| period p90 | 31.000 ms | **357 ms** |
| period max | 32.003 ms | **4667 ms** |
| duration p90 | 0.723 ms | **336.632 ms** |
| duration max | 1.031 ms | **4648 ms** |

The median holds; 10 % of cycles exceed 336 ms and the worst blocks 4.6 s.
Period tracks duration almost exactly, so the CALLBACK ITSELF runs long — this
is not preemption. Corroborated independently: the demo's host-side
`ros2 topic hz` read **3.19 Hz** on the wire, and 1/0.32 s ~= 3 Hz.

This also retires W3's orphaned 62.102 ms `main` slice: that was this same
tail seen without load, which is why it looked anomalous against a 0.669 ms
median.

Evidence archived (gitignored): `tools/rt-eval-traces/loaded-drive.ctf.gz`,
trimmed to the boot+mission window and verified to decode identically first.

Caveats, stated because they bound the result:

- `route_state` never reached ARRIVED and the demo warns the goal may be the
  hand-probed fallback rather than map-derived, so the SCENARIO is not
  textbook-clean even though the load is real.
- One cycle unclosed at capture end (950 enter / 949 exit).
- WHAT consumes the 336 ms is NOT established. The markers bracket the whole
  callback, not its phases — see W7.

### Three defects fixed to get here  [x]

- [x] `run-tap-demo.sh` never started the SNTP responder, and the tap image
      blocks on it at boot. The demo could not boot standalone at all.
- [x] `CONFIG_HEAP_MEM_POOL_SIZE` 4 MiB -> 192 KiB (nano-ros 589a9d0): silent
      hang after SNTP, never reached "Live".
- [x] `CONFIG_MAIN_STACK_SIZE` 512 KiB -> 16 KiB (same pin): reached "Live",
      then ZERO control cycles. The boot tier runs the executor on `main` and
      Layer 1 measured `main` using 96384 bytes, so 16 KiB could not survive a
      dispatch. Four further shrunk symbols restored as a set.

## W5-superseded — the original blocking-gap list

**Every number in W3 is from an idle system.** With no planner attached the
transport never contends with the control tier, so three results are
unvalidated under the conditions that matter:

- [x] ANSWERED by W7: `main`'s **62.102 ms** worst contiguous slice against a
      0.669 ms median was this same MPC tail seen without load —
      real, or an artefact of an idle executor?
- [x] **Stack headroom under load — ANSWERED 2026-08-27, and it found a third
      overflow.** Layer 1 report from a loaded driving mission:

      ```
      asi_sntp_resync    : unused    0  usage   4096 / 4096   (100 %)  <- overflowing
      net_socket_service : unused 1216  usage   2880 / 4096   ( 70 %)
      main               : unused 370928 usage 153360 / 524288 ( 29 %)
      tcp_work           : unused 1536  usage   2560 / 4096   ( 62 %)
      ```

      `asi_sntp_resync` was a hardcoded 4096 and reads 100 % — the analyzer
      clamping at the stack end. Re-measured at 8192 it needs **7024 bytes**,
      so it had been overrun 1.7x on every loaded run since periodic re-sync
      landed. Fixed: CONFIG_ASI_SNTP_RESYNC_STACK_SIZE, default 12288.

      The other two settle earlier questions: `main` uses 153360 under load
      against 96384 idle, so the 16 KiB the pin cut it to was short by ~10x,
      and 512 KiB is correctly sized at 29 %. `net_socket_service` needs 2880
      loaded, so the 1200 default it shipped with was overrun 2.4x — worse
      than the idle figure implied.

- [x] SUPERSEDED by the above: `net_socket_service` at 70 % of its (now
      4096-byte) stack, and
      `tcp_work` at 62 %. Both unloaded, and W2 proved this thread was already
      overflowing once.
- [x] CLOSED as no longer meaningful (2026-08-28). A 298 ms MPC solve swamps
      any effect a priority band could have: contention between the control
      tier and the transport cannot matter when the callback alone takes 10x
      its period. Worth revisiting only if the solve time is brought near
      budget. Original note:
      **Priority 5 vs 9 measured identical** — p50 6.0000 ms, p99 7.0000 ms,
      slice p50 0.6690 ms both ways. Expected on an idle transport, and NOT
      evidence the fix is inert; it means the priority relationship is never
      exercised. The W2 fix is correct by allocation and undemonstrated by
      measurement.

Unblocked by `run-tap-demo.sh --drive` (landed 2026-08-24, `1d838c5`), which
runs the autonomous mission in one command. Cost to be aware of:
`ghcr.io/autowarefoundation/autoware:universe-20250207` is not present locally
and the disk is at 95 % (300 GB free); the bridge and visualizer images build
locally and are small.

- [x] RECORDED (not work, a standing caveat): **the console clock is no longer
      a usable ground truth.** The WFI
      finding in W3 was established by comparing a capture against the
      target's own console timestamps (12.214 s). Periodic SNTP re-sync
      landed 2026-08-25 (phase-4, `common/clock/clock_resync.cpp`) and steps
      the island clock by −9.08 s every cycle on the tap demo. CTF timestamps
      come from `k_cycle_get_32()` and are unaffected, but any future
      calibration against console time must account for the steps — or use a
      capture shorter than one re-sync interval
      (`CONFIG_ASI_SNTP_RESYNC_INTERVAL_S`, default 10 s).
- [x] DONE: re-baselined against `36d08cf fix(safety): the
      island never goes silent, and NaN never leaves it` — it touches the MPC
      and PID controllers directly, so the W3 figures predate it.
- [x] DONE: captured under `--drive` (three successful missions). Stack
      headroom and the tail are answered; the priority 5-vs-9 comparison is
      NOT — it needs a loaded run at priority 5, which does not exist.

## W7 — where the tail goes  [x] ANSWERED 2026-08-27

**MPC lateral solve is the bottleneck.** Phase markers at the existing
PROFILE_POINT boundaries, second driving mission (peak 1.69 m/s, stopped
~0.9 m from goal), decoded from the SETTLED file after teardown:

```
phase                 p50 ms     p90 ms     max ms       n
inputs                22.696     49.054     81.062     246
mpc_lateral          251.792    335.867   4645.904     245
pid_longitudinal       3.921      6.577     22.888     245
publish                1.882      4.135     22.031     245
```

251.8 ms median against a 30 ms budget — **8x over** — with a 4.65 s worst
case. PID (3.9 ms) and publish (1.9 ms) are negligible. Input handling
(22.7 ms) is second-order but not nothing: on its own it consumes three
quarters of the period.

The phases reconcile with the cycle: 22.7 + 251.8 + 3.9 + 1.9 ~= 280 ms,
against a period p90 of 336 ms.

READ THE MEDIANS CAREFULLY. Overall `duration p50` is 1.373 ms while
`mpc_lateral p50` is 251.8 ms. Not a contradiction: 772 of 1018 cycles were
safe_stop, which exit before the controllers at ~1.4 ms, so the all-cycle
median IS a safe-stop cycle. The phase table covers only the 246 commanded
cycles. Separating them is the whole point — an aggregate median hides the
thing that matters.

This closes the chain: the loop misses its period because the MPC solve does
not fit in it, not because of scheduling, preemption, priority, or transport.
Every one of those was suspected at some point in this phase and each was
eliminated by measurement.

Follow-ups this opens (none investigated):

- [ ] Is 251.8 ms representative of the MPC configuration, or is this an
      unconverged/ill-conditioned solve? The 4.65 s worst case suggests the
      latter at least sometimes.
- [ ] `ctrl_period` is 30 ms but the solve needs ~250 ms. Either the period is
      aspirational for this platform or the solver needs bounding (iteration
      cap, horizon, warm start).
- [x] **Input handling split (W9, 2026-08-28) — the suspicion was WRONG.**
      Phase 4 suspected 8.8 KiB trajectory deserialization and so did I. It
      costs 0.169 ms. The time is in `isReady()`:

      ```
      in:process_data    0.011 ms   (flag checks)
      in:copy_inputs     0.169 ms   <- the 8.8 KiB deep copy: NOT the problem
      in:is_ready       33.952 ms   p90 52.670  max 4396.026
      inputs (total)    34.124 ms
      ```

      `isReady()` on the two controllers is 99.5 % of the input phase and
      exceeds the whole 30 ms period on its own. A readiness PREDICATE costing
      34 ms median and 4.4 s worst case is doing substantial work.

      **Mechanism found.** `MpcLateralController::isReady()` opens with

      ```cpp
      bool MpcLateralController::isReady(const InputData & input_data)
      {
        setTrajectory(input_data.current_trajectory, input_data.current_odometry);
      ```

      `setTrajectory()` resamples, filters and computes curvature over the
      trajectory. So this is not a predicate at all — it is trajectory
      PROCESSING behind a readiness-check name, running every cycle before
      anything decides whether the cycle will produce a command. That also
      explains why its max (4396 ms) tracks the MPC max (4610 ms): both are
      trajectory-size-driven work in the same vendored MPC path.

      Both consumers are in the VENDORED Autoware MPC code
      (`src/autoware/autoware_mpc_lateral_controller/`), not in ASI's own
      layer, so the remedy is a controller-configuration or upstream question
      rather than an integration one.

      Sample caveat: 141 commanded cycles (against 246 in the W7 run) and the
      vehicle parked ~6 m in rather than reaching the goal. Percentiles agree
      with the earlier run but the sample is smaller.

## W7-original — the question

- [x] ANSWERED — the MPC lateral solve. W5 showed 10 % of loaded control
      cycles exceeding 336 ms and a 4.6 s
      worst case, with period tracking duration — so the callback runs long
      rather than being preempted. WHICH PHASE is unknown: the markers bracket
      the whole callback. `callbackTimerControl` already carries PROFILE_POINT
      sites (`cyc_t0`, `cyc_t_ready`, `cyc_t_lat`, `cyc_t_lon`, `cyc_t_end`)
      that split it into input handling / MPC lateral / PID longitudinal /
      publish. Emitting those as `app_marker` phases would say whether this is
      solver time or a blocking DDS take.

## W6 — callback-level visibility  [x]

- [x] **Application markers in the CTF stream.** `app_marker` (id 0x70) added
      out-of-tree by `patches/zephyr/0002-ctf-app-marker-event.patch` — Zephyr
      3.7 has no user-event facility (upstream's `named_event` came later).
      `common/diag/trace_marker.hpp` is the app-side seam; the control callback
      is bracketed at entry and at all three exits, the exit marker carrying
      WHY the cycle ended. `parse-zephyr-ctf.py` decodes it with no change,
      because it reads the TSDL, and reports cycle period + duration +
      outcomes. Compiles away entirely when tracing is off.

### The defect it found immediately  [x] FIXED 2026-08-26

- [x] **The control loop ran at 151 ms, not the declared 30 ms.** ROOT-CAUSED
      AND FIXED. `modules/nros/zephyr/CMakeLists.txt:432` lowers the
      capability with `add_compile_definitions(NROS_SYSTEM_PARAM_SERVICES)`,
      which is DIRECTORY-SCOPED: it reaches the nros Zephyr module's own
      directory and never `src/controller_pkg`. The component therefore
      compiled with `ComponentNode::adopt_launch_seed_()` `#if`'d out, so
      `declare_parameter()` never consulted the executor's launch-seeded
      store — and EVERY launch parameter silently lost to its compiled
      default, not just `ctrl_period`.

      The freertos-posix lane was unaffected because
      `nano_ros_workspace(SYSTEM ...)` lowers the axes from a scope that
      parents the component directories. That asymmetry is why phase 4 fixed
      issue 0745 for posix and believed it covered both lanes.

      Fixed consumer-side in `actuation_module/CMakeLists.txt`, immediately
      before `add_subdirectory(src/controller_pkg)`. Upstream already names
      the proper follow-up ("resolve from the entry's BRINGUP like
      `nano_ros_workspace(SYSTEM ...)` does"); this is the interim.

      Measured, same workload, probe at construction then removed:

      ```
      before  adopted=0.150000 timer_ms=150   period p50=151.000 p99=152.000 n=1032
      after   adopted=0.030000 timer_ms=30    period p50= 31.000 p99= 31.002 n=5025
      ```

      Callback duration is unchanged (p50 0.721 ms), confirming the callback
      itself was never implicated.

- [ ] Follow-up: `min` period is 13.997 ms in the fixed run (p50 31.000), so a
      few cycles land early. Not investigated.
- [x] **Parameter audit (2026-08-27) — the blast radius is ONE value.** An
      earlier note here claimed "every launch parameter was equally dead ...
      the ~150 MPC/PID parameters all ran on compiled defaults". That
      overstated it, and the correction matters for regression risk:

      | | count | effect of the fix |
      |---|---|---|
      | declared by the controller (`declare_parameter`) | 131 | none |
      | declared by the launch (`<param>`, hence seeded) | 2 | the whole blast radius |
      | `ctrl_period` | 0.03 vs compiled 0.15 | CHANGED: 151 ms -> 31 ms |
      | `control_output` | `DDS_ONLY` vs `CONFIG_CONTROL_CMD_OUTPUT_DDS_ONLY=y` | no change, same value |

      The adoption MECHANISM was broken for any seeded parameter — that part
      of the finding stands and was worth fixing. But only two parameters are
      ever seeded, and one already matched its compiled default. The 131
      MPC/PID tuning values are declared with compiled defaults and are NOT
      launch-declared, so they read identically before and after.

      Consequence: the only behavioural change to validate is the control
      period, not a broad retune.

- [x] RESOLVED by W7: the callback's own cost is NOT the 62.102 ms `main`
      slice recorded in
      W3: duration p50 is 0.721 ms and max 1.456 ms. Whatever occupies that
      slice is elsewhere in the executor thread.
- [x] FILED as NEWSLabNTU/nano-ros#5 (2026-08-28): the generic pool spawns via
      `pthread_create` with no name, while the tier path calls
      `k_thread_name_set`; `pthread_setname_np` exists in Zephyr 3.7, so the
      fix is a name parameter plus one call. Original note:
      nano-ros's generic pool threads are unnamed (`k_thread_name_set` is
      called for tier threads only), so the seven transport threads appear as
      `unknown` and are separable only by thread id and stack base. Worth
      raising upstream — it would make any control-loop timeline substantially
      more readable.

## Non-goals

- SEGGER SystemView and Percepio Tracealyzer. SystemView wants a J-Link, which
  the FVP cannot offer — revisit on S32Z hardware. Tracealyzer is licensed and
  its AArch64-R port is unconfirmed; not fetched by ASI's flat west manifest.
- FVP plugin/MTI tracing. Zero-perturbation and therefore the tie-breaker if
  the on-target tracer's own overhead ever becomes the suspect, but it sees
  instructions and addresses rather than Zephyr threads.
