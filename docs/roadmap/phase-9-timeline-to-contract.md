# Phase 9 — from timeline to contract

Status: **complete** (2026-08-30). Scope: turn the captured timeline
into numbers the scheduling contract can accept, and check the contract against
what actually ran.

Phases 7 and 8 answered *where the time goes*. This one answers three
different questions:

1. does the schedule match what was declared,
2. what is preempting what, and
3. what execution-time budget should the contract carry.

Design reference: `docs/design/rt_evaluation_zephyr.rst` (mechanisms),
`docs/design/callback_tracing.rst` (per-callback spans).

## The gap this phase exists to close

**Everything phases 7 and 8 measured is wall-clock, not execution time.**
`mpc_lateral` at 227.5 ms is an enter-to-exit span; it includes any interval
where the thread was switched out. `TierSpec::budget_us` wants CPU time.

So no published figure can be fed back as a budget without correction, and the
correction is computable: `thread_switched_out` / `thread_switched_in` bracket
exactly the stolen intervals, and every marker can be attributed to whichever
thread was running when it was emitted.

## What the contract can accept

`TierSpec` (`packages/platform/nros-platform/src/board/tier.rs`) already
carries the fields, so this is feedback into an existing shape rather than a
new one:

| field | what phase 9 can supply |
|---|---|
| `priority` | observed, from `thread_priority_set` |
| `spin_period_us` | observed dispatch period |
| `core` | observed thread-to-CPU mapping |
| `class`, `period_us` | conformance check only |
| `budget_us` | **observed execution-time maximum** |
| `deadline_us` | **observed response-time maximum** |
| `deadline_policy` | untouched; a human decision |

## Work items

### W1 — execution time, not wall time  [x] DONE 2026-08-30

Attribute every marker to the thread running at that instant (from the switch
timeline), then subtract from each span the intervals where that thread was not
running. Report execution time alongside wall time; do not replace it, because
response time is what a deadline is measured against.

Reprices every figure in phases 7 and 8.

### W2 — preemption accounting  [x] DONE 2026-08-30

Per callback: how many times it was preempted, by which threads, and how much
time was taken. Phase 7 concluded "slow, not preempted" by INFERENCE from
period tracking duration. This measures it.

### W3 — schedule conformance  [x] DONE 2026-08-30

Compare declared against observed and flag divergence:

* declared: `system.toml` `[tiers.*]` plus the launch `ctrl_period`
* observed: `thread_priority_set` events, dispatch periods, thread mapping

This class of check already caught a real violation by hand — the control tier
declared priority 5 while nano-ros RFC-0079 puts the DDS transport at 7, so the
tier could preempt the transport it depends on. Mechanising it is the point.

### W4 — budget and deadline extraction  [x] DONE 2026-08-30

Emit candidate `budget_us` and `deadline_us` per tier from the W1 numbers, in a
form that can be pasted into `system.toml`.

## Acceptance criteria

- [x] Execution time and wall time reported separately, and they differ. The
      control callback: wall max 393.510 ms, exec max 226.969 ms.
- [x] Preemption is attributed to a named preempting thread — `rx_q[0]`,
      `sysworkq`, and an unnamed nano-ros pool thread.
- [x] A deliberately wrong declared priority is FLAGGED. Verified by feeding
      the check a `system.toml` altered to `priority = 5`: `!! tier priority
      (Zephyr, on main) declared 5, observed 9`.
- [x] Suggested budgets are emitted with their basis stated (`budget_us` =
      exec max, `deadline_us` = wall max), under an explicit note that these
      are observed maxima on the FVP, not WCET and not silicon.

## Results

Run:

```
python3 scripts/parse-zephyr-ctf.py <trace> \
    --contract actuation_module/src/controller_bringup/system.toml \
    --launch   actuation_module/src/controller_bringup/launch/system.launch.xml
```

### W1/W2 — and a phase-7 conclusion corrected

```
callback                     n   wall p50  wall max  exec p50  exec max  preempted
timer@30000us              881      1.401   393.510     1.274   226.969  19399.585
/planning/.../trajectory   218      0.996     4.409     0.995     2.019      7.304
/localization/kinematic_state 359   0.088     0.090     0.088     0.090      0.000
/localization/acceleration 359      0.047     0.049     0.047     0.049      0.000
/vehicle/status/steering_status 359 0.006     0.008     0.006     0.008      0.000
/system/operation_mode/state  3     0.005     0.006     0.005     0.006      0.000

  timer@30000us: preempted by unknown (0x00281cc0) 8653.859 ms,
                 rx_q[0] 7997.137 ms, sysworkq 2090.543 ms
```

`exec max` 226.969 ms lands on the 227 ms MPC figure, so phase 7 was right that
the solve dominates CPU time.

**But phase 7 W7 also said the callback "runs long rather than being
preempted", and that is wrong.** It was inferred from period tracking duration,
never measured. 166 ms of the 393 ms worst case is time off CPU, and 19.4 s in
total across the run — mostly `rx_q[0]` and an unnamed nano-ros pool thread.
Both things are true at once: it runs long AND it is preempted.

Corrected in `rt_evaluation_zephyr.rst` rather than only here, since that is
the durable write-up.

### W3 — conformance

```
OK tier priority (Zephyr, on main)    9
!! control period (us)                declared 30000, observed 32000
1 conforming, 1 divergent
```

The divergence is real and already known: the loop does not hold its period.
The value of the check is that it is now mechanical rather than a hand
comparison, and it catches the priority class of bug that was found by eye in
phase 7.

### W4 — suggested contract values

```
timer@30000us                  budget_us =  226968   deadline_us =  393510
/planning/.../trajectory       budget_us =    2019   deadline_us =    4408
/localization/kinematic_state  budget_us =      89   deadline_us =      89
/localization/acceleration     budget_us =      49   deadline_us =      49
/vehicle/status/steering_status budget_us =      7   deadline_us =      7
/system/operation_mode/state   budget_us =       5   deadline_us =      5
```

Note what the first row says: a 226968 us budget against a 30000 us period is
not a budget, it is a statement that the workload does not fit. That is the
phase-7 conclusion arriving through a different route.

## Caveats that ride with every number this phase produces

- **Observed maximum is not WCET.** It is a high-water mark over the runs
  taken. Calling it WCET would be the same false confidence this campaign
  keeps finding in its own output.
- **FVP absolute times are not silicon** (phase 7 W12). Budgets derived here
  are structurally useful and numerically wrong for hardware. Ratios survive
  the model; absolute times do not.
- **Per-callback coverage is partial.** 3 of 33 leaf sites are hooked
  (phase 8), so only the timer and the C-FFI subscription path produce spans.
  W3 conformance is complete; W4 budgets cover what is instrumented.

## Non-goals

- Static WCET analysis. Nothing here bounds the worst case; it observes.
- Changing the contract. This phase produces numbers and a report. Editing
  `system.toml` is a controls decision.
