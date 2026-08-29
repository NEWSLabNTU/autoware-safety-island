# Phase 7 — real-time evaluation of the Zephyr FVP lane

Status: **complete** (2026-08-21 → 2026-08-28), with one question DEFERRED to
silicon (see W12) and one uninvestigated curiosity. Scope: measure the
scheduling behaviour of the safety island on its production target, and build
the tooling that makes those measurements repeatable.

**Follow-on.** The markers this phase hand-placed are the wrong long-term
shape — only the control timer was ever instrumented, so the subscription
callbacks remain unmeasured. Phase 8
(`phase-8-callback-tracing.md`, design in `docs/design/callback_tracing.rst`)
moves the boundary instrumentation into nano-ros's executor dispatch so every
callback is covered without hand placement.

**Conclusion.** The control loop does not meet its 30 ms period, and the cause
is the MPC solve — not scheduling, preemption, tier priority, transport, or
the port, each of which was a hypothesis killed by a measurement. Cost is
`0.0821 * N^2 + 21.75` ms in `mpc_prediction_horizon`, with a ~42.4 ms
horizon-independent floor across the commanded cycle. Whether that floor is
real is NOT decidable on this platform: the FVP is an Arm Fast Model
(programmer's view, not cycle-accurate), so its wall-clock is a simulator
property. Ratios survive the model; absolute times do not. The durable
write-up is `docs/design/rt_evaluation_zephyr.rst`; this file is the work log. Distinct from phase 4's rate
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

## W12 — the horizon sweep  [x] DONE 2026-08-28

W11 argued from matrix shapes that the residual 227 ms is the QP and scales
with `mpc_prediction_horizon`. That was an estimate. This measures it.

Method: seed `mpc_prediction_horizon` from the launch (it was one of the 67
parameters with no runtime path — see below), rebuild, and run
`ASI_DEMO_BUILD_ARGS=--trace scripts/run-tap-demo.sh --drive` per point,
decoding the SETTLED trace after teardown. Seeding was verified at build time
in `actuation_entry_nros_main_generated.cpp` (`mpc_prediction_horizon", "25"`)
rather than assumed.

| N | lookahead | `mpc_lateral` p50 | p90 | max | commanded cycle | period p90 | period max |
|---|---|---|---|---|---|---|---|
| 50 | 5.0 s | **226.937 ms** | 306.2 | 4521.4 | 261.1 ms | 270 ms | 4560 ms |
| 25 | 2.5 s | **73.046 ms** | 90.2 | 4366.0 | 94.5 ms | 113 ms | 4408 ms |
| 15 | 1.5 s | **43.886 ms** | 67.5 | 97.4 | 64.7 ms | 81 ms | 176 ms |

**The cost model is confirmed.** A two-parameter fit on the outer points:

```
mpc_lateral = 0.0821 * N^2 + 21.75 ms
  N=50  measured 226.937  model 226.937
  N=25  measured  73.046  model  73.046
  N=15  measured  43.886  model  40.216   (+8.4 %)
```

The quadratic term is the matrix products W11 identified; 8.4 % residual at
N=15 is the O(N) assembly the two-parameter form does not carry. Halving N
from 50 costs 3.11x, an implied exponent of 1.64 — superlinear, as predicted,
and nothing like the linear scaling a data-movement bottleneck would show.

**The N=50 baseline reproduces across missions.** 226.937 ms here against
227.5 ms in W10, on a different mission (peak 2.57 vs 1.69 m/s). `mpc_lateral`
is mission-insensitive and N-driven. `in:is_ready` is NOT — it reads 30.6 /
16.9 / 17.1 ms across these three runs and 21.85 ms in W10, i.e. it varies as
much at constant N as across the sweep. Do not read an N-dependence into it;
the trajectory pipeline does not use the horizon.

**The tail collapses.** Period p90 goes 270 -> 113 -> 81 ms. The multi-second
outliers (4.5 s at N=50, 4.4 s at N=25) are simply absent at N=15, whose worst
`mpc_lateral` is 97 ms. Whatever produces them needs a long solve to land on.

### What this does NOT do: meet the 30 ms period

The fit has an N-independent floor of **21.75 ms inside `mpc_lateral` alone**.
Adding the rest of the commanded cycle at their measured values:

```
inputs ~17.0  +  mpc floor 21.75  +  pid ~2.6  +  publish ~1.05  =  ~42.4 ms
```

So on the FVP **no horizon meets 30 ms** — not N=15 (64.7 ms), not N=1. The
horizon is a real and large lever (5.2x from 50 to 15) and it cannot close
this gap. That is consistent with W11 rather than a surprise: if the FVP
wall-clock is a simulation artifact, the floor is an artifact too, and no
amount of tuning inside the guest removes it. It does mean the sweep cannot be
used to argue that some N is "fast enough" — that argument still needs silicon.

### Observation, n=1, not a claim

N=25 and N=15 both reached the goal (`route_state=3`, ARRIVED). N=50 parked
~4.6 m short with `route_state` never reaching 3, on a map-derived goal, which
`run-tap-demo.sh` documents as the case that normally arrives within ~0.1 m.
A 4.4 Hz control loop tracking worse than a 15 Hz one is plausible, but this is
one run per configuration with no repeats and no control over planner
variation. Recorded because it is the only control-QUALITY signal in the
campaign so far; it is not evidence.

### The knob now exists

`mpc_prediction_horizon` is seeded from `system.launch.xml` **at its compiled
default of 50**, so this lands as a no-op. It is left in place because W11
noted all 69 MPC parameters had no runtime path, and a lever this large should
be owned by the deployment rather than a C++ literal. Changing it is a controls
decision: N * `mpc_prediction_dt` is the prediction lookahead, so N=15 buys the
speed above by giving up 5.0 s of lookahead for 1.5 s.

Evidence: `tools/rt-eval-traces/phase7-w12-n{50,25,15}-decode.txt` (gitignored).

## W11 — hot-path duplicate-work audit  [x] DONE 2026-08-28

W10 was found by *reading* the control cycle rather than measuring it, and it
paid 25 %. This is the same read applied to the rest of the hot path. Result:
**the pattern does not recur, and the remaining cost is not where W9/W10 were
looking.**

**`PidLongitudinalController` is clean.** Its `isReady()` is literally
`return true;` — no work to duplicate. `run()` does its own `setTrajectory` /
`setKinematicState` / `setCurrentAcceleration` / `setCurrentOperationMode`
once. Nothing to fix.

**`MPC::setReferenceTrajectory` has no internal duplication.** It is a linear
pipeline: nearest-segment search, `convertToMPCTrajectory`, spline resample,
`isDrivingForward`, optional smoothing, optional yaw extension,
`calcTrajectoryYawFromXY`, `convertEulerAngleToMonotonic`,
`calcTrajectoryCurvature`, terminal point. Each stage consumes the previous.

Two of its blocks never execute here, which corrects a standing suspicion:

| block | gate | compiled default |
|---|---|---|
| 4x `filt_vector` moving average | `enable_path_smoothing` | **false** |
| `extendTrajectoryInYawDirection` | `extend_trajectory_for_end_yaw_control` | **false** |

Neither is launch-seeded (see the parameter audit below), so the moving-average
filter — repeatedly named as a cost suspect — is dead at runtime on this lane.

**There is no change-guard on the trajectory.** `setTrajectory` reprocesses
unconditionally every cycle, with no comparison against the previous message,
so when the planner publishes slower than the control loop the pure-message
stages (`isValidTrajectory`, `convertToMPCTrajectory`) redo identical work.
That is a genuine duplicate-work pattern — and it is **not worth acting on**,
because after W10 the whole trajectory pipeline is `in:is_ready` = 21.85 ms.
Caching a fraction of 22 ms cannot touch a 254 ms cycle. Recorded so the next
reader does not re-derive it.

### Where the 227 ms actually is

Post-W10 the split is unambiguous: trajectory pipeline 21.85 ms, MPC `run()`
227.5 ms. The cost is the QP, not the trajectory. Sizes read from
`generateMPCMatrix` with the default `vehicle_model_type = "kinematics"`
(`dim_x 3, dim_u 1, dim_y 2`) and `mpc_prediction_horizon = 50`:

| matrix | shape |
|---|---|
| `Aex` | 150 x 3 |
| `Bex` | 150 x 50 |
| `Cex` | 100 x 150 |
| `Qex` | 100 x 100 |
| `R1ex`, `R2ex` | 50 x 50 |

The cost function is `H = B' C' Q C B + R`, evaluated as `CB = Cex * Bex` then
`CB' * Qex * CB`:

- `Cex * Bex` — 100 x 150 x 50 = 750k MAC
- `CB' * Qex` — 50 x 100 x 100 = 500k MAC
- `... * CB` — 50 x 100 x 50 = 250k MAC

**~1.5M double MACs per cycle**, plus the `generateMPCMatrix` assembly loop and
a 50 x 50 solve. `qp_solver_type` defaults to `unconstraint_fast`, i.e. the
direct solve — the cheap path is already selected.

Every one of those matrices is an Eigen `MatrixXd` — heap-allocated, per cycle,
along with each intermediate temporary. That is the same pressure that forced
`CONFIG_HEAP_MEM_POOL_SIZE` from 192 KiB to 4 MiB (W2), and unlike the FVP
timing it is a real cost on silicon too.

### This bounds design question 1

The open question was whether 227 ms represents the MPC or is pathological.
~1.5M MACs is not a 227 ms workload on a Cortex-R52 with an FPU; it is a
low-single-digit-millisecond workload. `FVP_BaseR_AEMv8R` is an Arm Fast Model
— programmer's view, instruction-accurate, **not cycle-accurate** — so its
wall-clock is a simulation artifact and must not be read as a silicon number.
A ~100x gap is consistent with that and with nothing else.

Stated as a bound, not a measurement: the operation count is derived from the
matrix shapes above, not timed. What would settle it is a run on S32Z hardware
or a cycle-accurate model. **No further FVP capture can answer it** — which is
the useful part, because it stops the campaign from spending more captures on
a number the platform cannot produce.

### Parameter audit, MPC-lateral scope

`mpc_lateral_controller.cpp` makes **69** `declare_parameter` calls. The launch
seeds **two** parameters total (`control_output`, `ctrl_period`), neither of
them an MPC tuning value. So all 69 run on compiled defaults, including every
lever that would change the cost above — `mpc_prediction_horizon` (50) being
the dominant one, since the products scale as N^2 to N^3.

This is consistent with the earlier parameter audit and adds nothing to the
regression risk (defaults read identically before and after the seeding fix).
It does mean any future retune has no runtime path on this lane.

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

**The assertion was broken on its first real CI run (fixed 2026-08-28).** It
failed a healthy image whose worst thread was 70 %, reporting garbage rows like
`00: :/STACK: bytes (idle%)`. Two bugs, one enabling the other:

1. The name was captured as `([^ ]+)`, a single token. Zephyr's idle threads
   are named `idle 00` .. `idle 03` — with a space — so the pattern never
   matched them and the line reached `awk` unsubstituted.
2. `awk '$1 >= lim'` then compared the *string* `idle` against `85`. awk falls
   back to string comparison when a field is non-numeric, and `"idle" > "85"`
   because `i` sorts after `8`. Every idle thread became a breach.

Fixed by anchoring the name capture on the ` : STACK:` separator, normalising
to a fixed `OK <pct> <usage> <total> <name...>` shape, forcing numeric
comparison with `$2 + 0 >= lim + 0`, and — the part that matters for next time
— failing loudly on any line the pattern does *not* rewrite, instead of letting
it fall through a numeric test.

This corrects the claim above that it was "verified both directions against
real logs". The breach direction was verified; the healthy direction was
verified against a log that contained no space-named threads, which is exactly
the case that broke. Now checked against the real phase-6 `stats.log` (passes
at 85, reports `asi_thread_stats` 55 %, `net_socket_service` 70 %, `tcp_work`
61 % at 50), a synthetic malformed line, and an `idle 03` line in both
directions.

Worth stating plainly: a CI assertion that has only ever been exercised by
hand-made inputs is not yet an assertion. This one's first contact with a real
artifact was also its first failure.

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

- [x] **ANSWERED by W11 + W12: representative, and not ill-conditioned.** The
      cost is `0.0821 * N^2 + 21.75` ms across N = 50/25/15, a clean fit to the
      QP's matrix products. An unconverged or ill-conditioned solve would not
      track the horizon quadratically. `qp_solver_type` is already
      `unconstraint_fast` (direct solve, no iteration to cap), so there is no
      iteration count to be unconverged in. The multi-second worst cases are a
      separate tail — they vanish at N=15 (max 97 ms), so they need a long
      solve to land on rather than being a distinct pathology.
- [~] **PARTLY ANSWERED — deferred to silicon.** W12 measured the horizon
      lever end to end: 5.2x from N=50 to N=15. It is not enough. The
      N-independent floor is ~42.4 ms of commanded cycle, so **no horizon meets
      30 ms on the FVP**, and bounding the solver further cannot either. Per
      W11 the FVP wall-clock is a Fast Model artifact (programmer's view, not
      cycle-accurate), which makes the floor an artifact too. Unblocks on: a
      run on S32Z hardware or a cycle-accurate model. Until then this is a
      controls decision that the FVP cannot inform — the campaign should stop
      spending captures on it.
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
