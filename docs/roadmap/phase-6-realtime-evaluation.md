# Phase 6 — real-time evaluation of the Zephyr FVP lane

Status: **in progress** (started 2026-08-21). Scope: measure the scheduling
behaviour of the safety island on its production target, and build the tooling
that makes those measurements repeatable. Distinct from phase 4's rate
profiling, which was FreeRTOS-POSIX-side and host-measured; this track is
target-side, on `fvp_baser_aemv8r`.

Survey date: 2026-08-25. Legend: [x] done, [ ] planned, [~] deliberately
deferred (with the condition that unblocks it).

Design reference: `docs/design/rt_evaluation_zephyr.rst` — mechanism survey,
measured results, and the caveats that bound each. Upstream defects found on
the way: `docs/design/upstream-zephyr-issues.md`.

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

- [~] **Filing is deferred** (owner decision, 2026-08-24). One command when
      wanted: `scripts/file-upstream-issues.sh --create`.
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

## W5 — loaded measurement  [ ]  ← the blocking gap

**Every number in W3 is from an idle system.** With no planner attached the
transport never contends with the control tier, so three results are
unvalidated under the conditions that matter:

- [ ] `main`'s **62.102 ms** worst contiguous slice against a 0.669 ms median —
      real, or an artefact of an idle executor?
- [ ] `net_socket_service` at **70 %** of its (now 4096-byte) stack, and
      `tcp_work` at 62 %. Both unloaded, and W2 proved this thread was already
      overflowing once.
- [ ] **Priority 5 vs 9 measured identical** — p50 6.0000 ms, p99 7.0000 ms,
      slice p50 0.6690 ms both ways. Expected on an idle transport, and NOT
      evidence the fix is inert; it means the priority relationship is never
      exercised. The W2 fix is correct by allocation and undemonstrated by
      measurement.

Unblocked by `run-tap-demo.sh --drive` (landed 2026-08-24, `1d838c5`), which
runs the autonomous mission in one command. Cost to be aware of:
`ghcr.io/autowarefoundation/autoware:universe-20250207` is not present locally
and the disk is at 95 % (300 GB free); the bridge and visualizer images build
locally and are small.

- [ ] **The console clock is no longer a usable ground truth.** The WFI
      finding in W3 was established by comparing a capture against the
      target's own console timestamps (12.214 s). Periodic SNTP re-sync
      landed 2026-08-25 (phase-4, `common/clock/clock_resync.cpp`) and steps
      the island clock by −9.08 s every cycle on the tap demo. CTF timestamps
      come from `k_cycle_get_32()` and are unaffected, but any future
      calibration against console time must account for the steps — or use a
      capture shorter than one re-sync interval
      (`CONFIG_ASI_SNTP_RESYNC_INTERVAL_S`, default 10 s).
- [ ] Re-baseline the idle capture first against `36d08cf fix(safety): the
      island never goes silent, and NaN never leaves it` — it touches the MPC
      and PID controllers directly, so the W3 figures predate it.
- [ ] Then capture under `--drive` and re-run all three questions above.

## W6 — callback-level visibility  [ ]

- [ ] The timeline sees executor wakes, not control-callback boundaries, so
      control-loop LATENCY is still not measurable — only cadence and cost.
      Callbacks execute inside a wake as ordinary function calls. Needs either
      a marker around the callback in nano-ros, or an application shim. Until
      then, "is the control callback meeting its 30 ms deadline" cannot be
      answered from a capture.
- [ ] nano-ros's generic pool threads are unnamed (`k_thread_name_set` is
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
