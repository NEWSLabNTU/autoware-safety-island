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

### W1 — pin the exact hook site  [ ]

`executor/dispatcher.rs` declares the one-method `Dispatch` trait ("Drain
`ready` and fire each callback"); `executor/spin.rs` implements it in ~7.8k
lines and carries `dispatch_callback(&mut self, cb_id: &str, ctx)` plus a
`DispatchSlot` type. The trait is the boundary; the precise per-callback fire
site inside the impl still needs to be read.

Deliverable: the exact function and line where each callback kind (timer,
subscription, service, action) is invoked, and confirmation that a single pair
of hooks covers all four. If it does not, say so — a partial hook is worse than
none, because it looks like coverage.

### W2 — callback identity  [ ]

`cb_id: &str` already exists on the dispatch path. Settle whether it is stable,
unique, and cheap enough to be the runtime handle, or whether runtime events
should carry an integer index with `cb_id` recorded once at registration.

Prefer the integer. ros2_tracing's init/runtime split exists precisely to keep
string payloads out of the hot path.

### W3 — the hooks and the feature gate  [ ]

Emit, in nano-ros:

- `nros_callback_register(handle, kind, name)` — once, at registration
- `callback_start(handle)` / `callback_end(handle)` — per dispatch

Behind a **Cargo feature**, so the call site is eliminated when disabled.

Explicitly NOT on the `tracing` crate facade unless it is also compiled out: a
no-op subscriber still costs span construction and a level check on every
dispatch, and needs `max_level_off` to actually vanish. See the warning in the
design doc.

### W4 — Zephyr backend binding  [ ]

Route the hooks to the existing out-of-tree `app_marker` CTF event
(`patches/zephyr/0002`). No new Zephyr patch required. Keep the platform
binding behind whatever nano-ros already uses for board-specific glue rather
than putting Zephyr specifics in the executor.

### W5 — decoder support  [ ]

`scripts/parse-zephyr-ctf.py` gains: build the handle→name table from the
registration events, then report per-callback dispatch counts and
duration percentiles, the way it already does for control cycles.

This is the point at which the phase pays off — per-callback numbers for
callbacks nobody thought to instrument.

### W6 — retire the superseded markers  [ ]

Delete `Marker::control_cycle_enter` / `control_cycle_exit` (values 1 and 2)
from `trace_marker.hpp` and their call sites; the dispatch hooks supersede them
exactly. **Keep** the phase markers (3–7) — they answer a different question
(where time goes *inside* a callback) and they are what found the MPC solve and
the duplicated `setTrajectory`.

Do not renumber the remaining markers. The header's own warning applies: values
appear in captured traces, and renumbering silently reinterprets every trace
taken before it. Leave the gap at 1–2.

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

## Acceptance criteria

- [ ] A capture attributes time to **every** registered callback, including
      ones with no hand-placed instrumentation
- [ ] Callback names in the decoder come from registration events, not from a
      compiled-in enum
- [ ] With the feature disabled, the dispatch path is byte-identical to today
      (verify by disassembly or size diff, not by assertion)
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
