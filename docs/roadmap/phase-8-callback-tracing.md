# Phase 8 — callback-level tracing

Status: **planned** (opened 2026-08-29). Scope: make the *callback* the unit of
observation instead of the thread, by instrumenting nano-ros's executor
dispatch boundary rather than hand-placing markers in application code.

Design: `docs/design/callback_tracing.rst` — problem statement, prior art
(tokio / Go / ros2_tracing / Zephyr 4.3 Instrumentation), event schema,
overhead analysis, and the alternatives considered and declined.

Motivation, in one line: phase 7 could only measure the control loop because
someone hand-placed seven markers in `controller_node.cpp`, and the
subscription callbacks — which were never under suspicion, and therefore never
instrumented — remain entirely unmeasured to this day.

Phase numbering note: 8 was free at the time of writing. Phase 6 is the
emulated R52 lane and phase 7 is the real-time evaluation track. If the
upstream migration sequence needs this number, renumber — the sequence is not
this track's to allocate from.

## Where the work lands

Two repos. Most of it is upstream.

| repo | change |
|---|---|
| nano-ros | dispatch hooks, registration events, Cargo feature gate |
| this repo | Zephyr backend binding, decoder support, retire markers 1–2 |

## Work items

### W1 — pin the exact hook site  [x] DONE 2026-08-29

`executor/dispatcher.rs` declares the one-method `Dispatch` trait ("Drain
`ready` and fire each callback"); `executor/spin.rs` implements it in ~7.8k
lines and carries `dispatch_callback(&mut self, cb_id: &str, ctx)` plus a
`DispatchSlot` type. The trait is the boundary; the precise per-callback fire
site inside the impl still needs to be read.

Deliverable: the exact function and line where each callback kind (timer,
subscription, service, action) is invoked, and confirmation that a single pair
of hooks covers all four. If it does not, say so — a partial hook is worse than
none, because it looks like coverage.

### W2 — callback identity  [x] DONE 2026-08-29

`cb_id: &str` already exists on the dispatch path. Settle whether it is stable,
unique, and cheap enough to be the runtime handle, or whether runtime events
should carry an integer index with `cb_id` recorded once at registration.

Prefer the integer. ros2_tracing's init/runtime split exists precisely to keep
string payloads out of the hot path.

### W3 — the hooks and the feature gate  [x] DONE 2026-08-29

Emit, in nano-ros:

- `nros_callback_register(handle, kind, name)` — once, at registration
- `callback_start(handle)` / `callback_end(handle)` — per dispatch

Behind a **Cargo feature**, so the call site is eliminated when disabled.

Explicitly NOT on the `tracing` crate facade unless it is also compiled out: a
no-op subscriber still costs span construction and a level check on every
dispatch, and needs `max_level_off` to actually vanish. See the warning in the
design doc.

### W4 — Zephyr backend binding  [x] DONE 2026-08-29

Route the hooks to the existing out-of-tree `app_marker` CTF event
(`patches/zephyr/0002`). No new Zephyr patch required. Keep the platform
binding behind whatever nano-ros already uses for board-specific glue rather
than putting Zephyr specifics in the executor.

### W5 — decoder support  [x] DONE 2026-08-29

`scripts/parse-zephyr-ctf.py` gains: build the handle→name table from the
registration events, then report per-callback dispatch counts and
duration percentiles, the way it already does for control cycles.

This is the point at which the phase pays off — per-callback numbers for
callbacks nobody thought to instrument.

### W1/W2/W5 results

**W1 answered, and it invalidated the starting assumption.** The `Dispatcher`
trait named as the hook site in the first draft of the design has NO
implementation — `#[allow(dead_code)]`, for a "110.A.b spin_once rewire" that
never landed. Hooking it would have compiled and traced nothing.

The real answer: all three dispatch paths (normal drain `spin.rs:5968`,
trigger-fail `spin.rs:5618`, OS-priority worker `os_priority.rs:140`) call the
*same* `CallbackMeta::try_process` pointer, and all 19 such symbols are defined
in `arena.rs`. So leaf hooks there cover every path. Cost is **33 sites, not
the handful first estimated** — 16 of them subscription variants. Guard
condition is a fifth `EntryKind` the original four-kind framing missed.

Three paths fire user code outside the arena and are declared out of scope:
lifecycle transitions (`lifecycle.rs:339`, `:202`), component tick
(`spin.rs:6253`), and the RTIC/Embassy `dispatch_callback` seam
(`spin.rs:3358`). Resolved on the way: `parameter_services.rs` reaches no user
callback at all across 2205 lines, so two suspected sites need no hook.

**W2 answered better than the design assumed.** `HandleId` IS the entry slot
index — stable (slots are never recycled; `cancel_timer` only sets a flag),
unique across all seven kinds (one flat table, all 24 registrations draw from
`next_entry_slot()`), and one byte (`MAX_CALLBACK_SLOTS = 64`, already
`DescIdx = u8`). The `cb_id: &str` the design pointed at belongs to a
different subsystem entirely.

**W5 done, and it found a phase-7 defect on the way.** The cycle `duration`
walk closed a cycle at the next marker of ANY id rather than at EXIT, so a
commanded cycle measured `ENTER -> data_checked`. Fixed in `f966822`; N=50 max
went 20.779 ms -> 4545.673 ms. The phase breakdown was verified byte-identical
before and after, so no W12 conclusion moves. See that commit for the full
blast-radius analysis.

**Done, decoder-side.** `parse-zephyr-ctf.py` now records every handle
registered twice under DIFFERENT names and prints, above the table:

```
!! HANDLE COLLISION -- these rows merge distinct callbacks:
     handle 3: alpha / beta
```

Chosen over an executor id in the register payload because it needs no upstream
change and no wire-format change, and because the decoder is where the damage
would land: a colliding handle makes its row the SUM of two unrelated callbacks
rather than a measurement.

Verified by a synthetic capture, not by inspection -- one handle registered as
`alpha` then `beta`, three dispatches, and the guard fires while the row shows
the merge it is warning about. The existing real capture decodes byte-identical,
so nothing regressed.

The upstream fix (an executor id in the register payload) is still the better
answer if multi-executor images become normal; this makes the failure visible
in the meantime, which is the property that matters.

### W5a — registration names bind by adjacency  [ ] follow-up

The `app_marker` CTF event carries exactly two `uint32`s, so a variable-length
name is streamed as 4-byte chunks (marker id 17) that bind to the register
event they FOLLOW — by position, not by handle. A dropped event inside a
registration burst therefore mis-attributes a name. Accepted because
registration is init-time, once per callback, single-threaded, and because a
wrong *name* cannot corrupt a *duration* (runtime events carry only the
handle). Revisit if it ever bites; the fix is a wider CTF event, which costs a
new Zephyr patch.

### W6 — retire the superseded markers  [x] WITHDRAWN 2026-08-30

**Do not do this. The premise was wrong.**

This item said the dispatch hooks "supersede markers 1-2 exactly" and cited the
2943-vs-2942 cross-check as proof. That cross-check proved the *counts* match.
It did not prove the *information* is the same, and it is not:

| marker | what only it provides |
|---|---|
| `control_cycle_enter` (1) | the anchor for `in:process_data` and `inputs (total)` |
| `control_cycle_exit` (2) | the end of `publish`, and the `arg` carrying the OUTCOME |

`callback_start` / `callback_end` give the callback's timing. They cannot give
the outcome — `commanded` / `safe_stop` / `not_ready` is application semantics
and the executor has no idea about it — and they are not what
`parse-zephyr-ctf.py` anchors the phase breakdown on
(`PHASES = [("in:process_data", ENTER, CHECKED), ..., ("publish", LON, EXIT)]`).

Deleting markers 1-2 would therefore have broken the phase breakdown and thrown
away the outcome counts, in exchange for removing a duplication that does not
exist. The two layers answer different questions, which the design doc already
said; this work item contradicted it and nobody noticed because the cross-check
looked like proof.

Kept as a WITHDRAWN entry rather than deleted: the reasoning that produced it is
worth having on the record next to the reasoning that killed it.

### W7 — measure the overhead properly  [ ]

The design doc quotes 0.0788 % as a **count** share and says plainly that it is
not a time share and has never been measured in isolation. Close that gap:
per-event cost on this target, with the RAM backend rather than the
UART/`TRACING_SYNC` measurement rig.

Acceptance: a number with a stated method, or an explicit statement that it
could not be isolated. Not an extrapolation.

### W8 — overwrite-oldest RAM backend  [ ] (only if production tracing is wanted)

`CONFIG_TRACING_BACKEND_RAM` exists on the 3.7 pin but is **fill-once, not a
ring**: it stops at `buffer_full` and goes silent permanently. Useless as a
flight recorder, which is the only reason to run tracing in production.
`TRACING_BACKEND_DEFINE` takes a single `output` function, so overwrite-oldest
is a small addition.

Gated on someone actually wanting production tracing. Do not build it
speculatively.

### W3/W4 result — it works end to end

Captured on a real `--drive` mission, `tools/rt-eval-traces/phase8-callback-hooks-decode.txt`:

```
6 callbacks registered, 3756 dispatches paired
dropped: 1 unbalanced, 0 spanning a WFI counter jump, 0 out of order

callback                                kind            n   total ms   p50 ms    max ms
timer@30000us                           timer        2942  34656.437    1.137  1584.608
/planning/scenario_planning/trajectory  subscription   96    176.040    1.920     4.176
/localization/kinematic_state           subscription  238     20.647    0.088     0.090
/localization/acceleration              subscription  238     10.916    0.047     0.050
/vehicle/status/steering_status         subscription  237      1.365    0.006     0.008
/system/operation_mode/state            subscription    5      0.027    0.006     0.006
```

**Cross-check passes.** 2943 `control_cycle_enter` app markers against 2942
timer dispatches — two independent instrumentation paths agreeing to one event,
which is the capture ending mid-dispatch. That is the evidence the encoding and
the pairing are right.

**The open phase-7 question is closed.** Subscription-callback cost was never
measured, because only the control timer was ever hand-instrumented. It is
~209 ms against the timer's 34656 ms, about 0.6 %. W9 guessed the trajectory
deep copy was the problem and was wrong; this settles the same class of
question by measurement, for callbacks nobody thought to instrument.

Names resolve from registration events. The nameless timer synthesises as
`timer@30000us`, which independently confirms `ctrl_period = 0.03` reached the
image.

### W3a — handles are unique per EXECUTOR, not per image  [x] DONE 2026-08-30

The slot index is unique within one `Executor`. An image running several tier
executors emits colliding handles and the decoder silently merges two different
callbacks into one row. ASI runs a single executor today (the boot tier on
`main`), so it does not bite — but nothing detects it, and a silent merge is
the same "looks like coverage" hazard this phase exists to remove. Options: an
executor id in the register payload, or a decoder warning when one handle is
registered twice with different names.

## Acceptance criteria

- [ ] A capture attributes time to **every** registered callback, including
      ones with no hand-placed instrumentation
- [ ] Callback names in the decoder come from registration events, not from a
      compiled-in enum
- [~] ~~With the feature disabled, the dispatch path is byte-identical to
      today~~ **AMENDED — this criterion is not met, deliberately.**
      `CallbackMeta::try_process` gained an unconditional `u8` desc index so
      leaves can identify themselves; a feature-disabled build therefore
      carries one constant register argument per dispatch that the leaf
      ignores. Everything else (hook bodies, register emit, name synthesis)
      does compile out. The alternative was macro-generating 21 leaf
      definitions to make the signature cfg-dependent, which trades a register
      move for a large amount of unreadable code. Recorded as amended rather
      than quietly dropped, because the criterion was written before the
      leaf-identity problem was understood.
- [ ] FVP CI green
- [ ] The subscription-callback cost — currently unknown — is reported

## Risks

- **nano-ros is upstream.** The bulk of this is someone else's repo. Land it as
  an issue plus a focused PR; do not fork.
- **Hook placement can be subtly wrong.** A hook around the wrong scope (say,
  outside a retry loop) produces plausible numbers that are wrong. W1's
  deliverable is the defence against this.
- **Event volume.** Adding 2 events per dispatch is negligible against the
  4437/cycle the tracer already emits, but that ratio holds only while mutex
  tracing dominates. If mutex events are ever filtered out, re-check.

## Non-goals

- **CARET-style cross-node causal chains.** The island is one node. That is the
  layer above this one; revisit when the island is measured as part of a chain.
  See the in-tree study under `play_launch/docs/research/caret-analysis.md`.
- **Porting LTTng to Zephyr.** Not happening, and not needed — the CTF stream
  and our own decoder already do the job.
- **`-finstrument-functions` as the structural fix.** Recorded in the design
  doc as the right *deep-dive* tool (it would have found the duplicate
  `setTrajectory` immediately), but it multiplies an already-200 MB capture and
  is complementary rather than alternative.
