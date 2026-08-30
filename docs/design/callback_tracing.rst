..
 # Copyright (c) 2026, Arm Limited.
 #
 # SPDX-License-Identifier: Apache-2.0

#############################################
Callback-level tracing
#############################################

.. contents::
   :local:

Phase 7 measured the control loop and had to hand-place seven trace markers
inside the callback body to do it. That worked, and it does not scale. This
document is the design for fixing the underlying problem rather than the
instance.

Companion: ``rt_evaluation_zephyr.rst`` (the measurement stack the markers
feed). Implementation plan: ``docs/roadmap/phase-8-callback-tracing.md``.


The problem
===========

A CTF capture shows **threads**. The control callback does not run on a thread
of its own — it runs *inside* an executor wake, as an ordinary function call.
Thread-level tracing can therefore see the executor's cadence and cost, and
cannot see where any individual callback begins or ends.

This is not a ROS problem or a Zephyr problem. It is the general shape of
**logical execution units multiplexed onto fewer OS scheduling entities**, and
every runtime that does it has had to solve the same thing:

===============  ====================  =========================
runtime          payload               carrier
===============  ====================  =========================
tokio            task                  worker thread
Go               goroutine             M (OS thread)
Java / Loom      virtual thread        carrier thread
ROS 2            callback              executor thread
**this repo**    **control callback**  **the** ``main`` **thread**
===============  ====================  =========================

The tracer sees the carrier. The thing you want to measure is the payload.


Why the phase-7 markers are not the answer
==========================================

``include/common/diag/trace_marker.hpp`` defines seven marker sites, placed by
hand in ``controller_node.cpp``. They answered the phase-7 questions and they
are the wrong long-term shape:

* **Manual placement.** Every new callback needs someone to remember. The
  subscription callbacks have no markers at all today, so nothing is known
  about their cost — only the control timer was instrumented, because only it
  was under suspicion.
* **A hand-maintained registry.** The ``Marker`` enum *is* the handle-to-name
  mapping, hard-coded and compiled in. Its own header carries the warning:
  "Keep the values stable: they appear in captured traces, and a renumbering
  silently reinterprets every trace taken before it." That hazard is
  structural, not a discipline failure.
* **No callback identity.** The markers say "a control cycle began". They
  cannot say *which* callback ran, because there is only ever one instrumented.
  The moment a second callback group or tier exists, the scheme has nothing to
  distinguish them by.

The markers that split the cycle into *phases* (``inputs_done``,
``lateral_done``, ``longitudinal_done``) are a different and genuinely useful
layer — see `Relationship to the phase markers`_. It is the cycle
enter/exit pair that should not be hand-placed.


Prior art
=========

The pattern is unanimous: **instrument the multiplexer, not the payload.** The
dispatcher is the only place that knows both identities — which logical unit is
about to run, and on which carrier — so it is the only place that can emit a
correct boundary event.

* **tokio** instruments the runtime at poll boundaries. ``tokio-console``
  reports per-task Busy / Scheduled / Idle / Polls, with task identity
  independent of whichever worker thread happened to run it.
* **Go** instruments the scheduler: ``runtime/trace`` emits ``GoStart``,
  ``GoBlock``, ``GoUnblock``, and ``go tool trace`` reconstructs per-goroutine
  timelines from them.
* **ros2_tracing** instruments the rclcpp executor. Runtime events are
  ``rclcpp_executor_execute``, then ``callback_start`` / ``callback_end``.
  Measured overhead is microsecond-level per tracepoint, under 15 % mean
  latency — over LTTng-UST shared memory on Linux.
* **Zephyr 4.3.0** added an Instrumentation subsystem that does it in the
  compiler: ``-finstrument-functions`` injects entry/exit calls, records a
  callgraph with timestamps into RAM, drains over UART, and ``zaru.py``
  exports for Perfetto. Antmicro's Zephelin builds on it and emits CTF.

Two ideas transfer
------------------

**1. Hook the dispatch point, not the callback body.** One hook covers every
callback that will ever be registered, including ones not written yet. Nothing
to remember, nothing to forget.

**2. Split initialisation from runtime.** This is ros2_tracing's most
transferable idea and the one that removes our registry hazard. Registration
tracepoints (``rclcpp_callback_register``, ``rclcpp_timer_callback_added``)
record handle-to-symbol *once*, at init. Runtime events then carry only the
handle. The payload in the hot path stays minimal; the names stay
human-readable offline; and nothing is hard-coded into an enum that a later
edit can silently redefine.

What does not transfer
----------------------

Two of these look much closer than they are, and it is worth being explicit so
nobody re-investigates them:

* **ros2_tracing and CARET need LTTng** — which has no Zephyr port — **and a
  patched rclcpp.** We do not use rclcpp at all; we use nano-ros. The in-tree
  study at ``modules/nros/packages/cli/third-party/play_launch/docs/research/
  caret-analysis.md`` already identifies the forked-rclcpp requirement as "the
  major deployment cost".
* **CARET solves a larger problem** — cause-effect chains *across* nodes, with
  ``use_latest_message`` semantics and TILDE message IDs. The safety island is
  one node. CARET is the layer above this one, worth revisiting only when the
  island is measured as part of a chain.
* **Zephyr's Instrumentation subsystem is 4.3.0.** This repo is pinned to
  3.7.0 LTS. The *technique* is available to us; the subsystem is not.


Design
======

Where the hooks go
------------------

nano-ros has **no tracing hooks of any kind** today — verified by search across
``modules/nros/packages``.

.. warning::

   An earlier revision of this document named ``executor/dispatcher.rs`` as the
   hook site and described the boundary as "a single, narrow surface". Phase-8
   W1 investigated and **that was wrong on three counts.** Corrected below;
   recorded rather than quietly deleted, because the wrong version was pushed
   and someone may have read it.

   1. The ``Dispatcher`` trait in ``dispatcher.rs`` **has no implementation.**
      It carries ``#[allow(dead_code)]`` and a comment referring to a
      "110.A.b spin_once rewire" that never landed. There is no
      ``impl Dispatcher for`` anywhere in the tree. Hooking it would compile
      and trace nothing.
   2. ``dispatch_callback(cb_id, ctx)`` (``spin.rs:3344``) is **not** on the
      dispatch path. It is the Phase-216 framework seam for interrupt-driven
      runtimes (RTIC / Embassy), fanning a name-keyed call out to registered
      ``DispatchSlot``s. ``spin_once`` never calls it. It covers **zero**
      timer / subscription / service / action dispatches.
   3. **One hook pair does not cover all kinds.** See below.

The real dispatch is open-coded inside ``Executor::spin_once``
(``executor/spin.rs:5368``). Every callback kind — timer, subscription,
service, client, action server, action client, guard condition — is invoked
through one type-erased function pointer per arena entry::

    CallbackMeta::try_process:
        unsafe fn(*mut u8, u64) -> Result<bool, TransportError>   // arena.rs:53

Why a single pair around that pointer is not enough:

* **Granularity is wrong.** One ``try_process`` for an action server fires up
  to three distinct user callbacks (cancel, goal, accepted). A ring-buffered
  subscription fires the user callback in a ``while`` loop, once per queued
  message. Both would collapse into one start/end pair.
* **It over-reports.** ``Ok(false)`` — "ran, fired nothing" — is the common
  outcome for a timer that is not yet due. A hook at the pointer records a
  callback invocation for entries that never invoked one.
* **It under-covers.** Callback-firing paths that bypass the normal drain:
  ``spin.rs:5618`` (timers on a spin where the executor trigger does not pass),
  ``os_priority.rs:140`` (entries routed to a worker task — a *different
  thread*), ``spin.rs:6230``/``5645`` (lifecycle-service C callbacks), and
  ``spin.rs:6253`` (component tick).

Settled by W1 / W2: hook the leaves, key on the slot index
-----------------------------------------------------------

**All three dispatch paths funnel through the same leaf functions.** Verified:
the normal drain (``spin.rs:5968``), the trigger-fail timer path
(``spin.rs:5618``) and the OS-priority worker (``os_priority.rs:140``) all call
the *identical* ``CallbackMeta::try_process`` pointer with the same
``arena_base + offset`` data pointer. Every one of the 19 registered
``try_process`` symbols is defined in ``arena.rs`` — none lives anywhere else.

So hooking the leaf ``(entry.callback)(...)`` invocations inside ``arena.rs``
covers all three paths with no extra sites, and gives what the ``try_process``
boundary cannot:

* **True per-callback granularity.** An action server's cancel / goal /
  accepted callbacks are counted separately; a ring-buffered subscription's
  N queued messages are counted as N.
* **No false positives.** ``Ok(false)`` — "ran, fired nothing", the common
  outcome for a timer that is not yet due — emits nothing.

**Cost, honestly: 33 leaf sites, not the handful first estimated.** Sixteen are
subscription variants (triple-buffered, ring, borrowed, raw, raw+info,
raw+safety, C-FFI, LET pre-sampled), six action-client, five action-server, two
service, two service-client, one timer, one guard condition. Guard condition is
a fifth ``EntryKind`` that the four-kind framing above omits.

Identity
~~~~~~~~

``HandleId(usize)`` already exists (``executor/types.rs:669``) and *is* the
entry slot index. It is:

* **stable** — no code path writes ``entries[i] = None`` after registration;
  ``cancel_timer`` only sets a ``cancelled`` flag, so slots are never recycled
* **unique across all kinds** — one flat ``entries[]`` table, all 24
  registration sites draw from the same ``next_entry_slot()``
* **one byte** — ``MAX_CALLBACK_SLOTS = 64``, enforced by a ``u64`` ready-set
  bitmask; internally already typed ``DescIdx = u8``
* **already plumbed to C/C++** via ``set_handle_id``

The catch: inside a leaf, the only identity in scope is the *address*
``arena_base + meta.offset``. Unique and stable, but an address, not an index,
and ``arena_base`` is not reachable from the leaf. Two ways to close that, and
the second is preferred:

1. Publish an ``offset -> index`` map once at registration and resolve offline.
2. **Thread the index into** ``try_process`` — extend the pointer signature to
   ``unsafe fn(*mut u8, u64, u8)``. All three producers already have the index
   or can cheaply recover it (the drain has ``i``; the trigger-fail loop needs
   ``.enumerate()``; ``WorkItem`` needs a ``desc_idx: u8`` field). This removes
   the map entirely and makes attribution exact at the point of use.

One leaf needs a signature change either way: ``dispatch_feedback``
(``arena.rs:1768``) takes ``(data, offset, on_feedback)`` and has **no**
identity at all. Hook inside it, not at its two call sites — it returns without
firing when the payload is short, which would re-introduce the false positive.

Registration is exhaustive; instrumentation is staged
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

33 sites is more than one change should land at once, and a partially hooked
set is exactly the "looks like coverage and isn't" hazard this design exists to
avoid. Resolve it by separating the two halves:

* **Registration events cover every kind, from the start.** All 24 sites funnel
  through ``next_entry_slot()``, so refactoring that into an
  ``emplace(slot, meta, name)`` helper gives one choke point rather than 24
  edits.
* **Leaf hooks land in stages**, beginning with the kinds this repo actually
  runs — one timer plus the C-FFI subscription path.
* **The decoder reports the gap, and reports it as AMBIGUOUS.** A registered
  callback with no dispatch events gets a row with ``n = 0`` and dashes, plus a
  note naming it. That note matters: an empty row has two possible causes and
  the trace cannot tell them apart -- the callback genuinely never fired, or it
  fired and its leaf is one of the un-hooked sites. Printing ``n = 0`` alone
  would invite the reader to conclude "that callback never ran", which may be
  flatly untrue.

  An earlier revision of this document claimed the decoder prints
  ``registered, not instrumented``. It cannot: nothing in the stream
  distinguishes the two causes, and no such label was ever implemented. Fixed
  in the decoder by stating the ambiguity instead of resolving it falsely.

That way an incomplete hook set announces itself in the output instead of
looking like a measurement.

Out of scope, explicitly
~~~~~~~~~~~~~~~~~~~~~~~~

Three paths fire user code without touching the arena, and leaf hooks will
never see them. Named here so their absence is a decision rather than an
oversight:

* **Lifecycle transition callbacks** — ``lifecycle.rs:339`` (raw C fn pointer)
  and ``lifecycle.rs:202``, reached via ``spin.rs:6230`` / ``5645``.
* **Component tick** — ``spin.rs:6253``, reaching user code at
  ``node_runtime.rs:538``.
* **Framework** ``dispatch_callback`` — ``spin.rs:3358``, the RTIC/Embassy
  seam. A disjoint boundary; worth its own hooks only if those runtimes come
  into scope.

Resolved along the way: ``parameter_services.rs`` reaches **no** user callback
(2205 lines, zero occurrences of ``callback``, zero ``extern "C"``), so
``spin.rs:6211`` and ``5631`` need no hook. That had been an open question.

Concurrency is mandatory, not optional
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Because leaf hooks also fire from the OS-priority worker thread
(``os_priority.rs:140``), hook state must be thread-safe from day one — a
depth counter or per-thread stack, atomic or thread-local, never a bare
boolean. Dispatch can also nest: the component tick hands ``*mut Executor`` to
user code. The ``in_dispatch`` flag in ``nros-c`` is **not** a nesting guard —
it is a cooperative flag that blocking helpers poll in order to return
``NROS_RET_REENTRANT``, and the native Rust ``spin_once`` has no equivalent.

Event schema
------------

Named after ros2_tracing so the concepts — and, later, possibly the analysis
tooling — carry over at no cost:

**Initialisation (once, at registration):**

``nros_callback_register(handle, kind, name)``
  ``kind`` is timer / subscription / service / action. ``name`` is the topic,
  timer period, or symbol. Emitted when the callback is added to the executor.

**Runtime (per dispatch):**

``callback_start(handle)``
  Immediately before the callback is invoked.

``callback_end(handle)``
  Immediately after it returns.

Optionally ``nros_executor_execute(handle)`` ahead of ``callback_start`` if the
gap between "selected for execution" and "began executing" ever matters. Not
needed for the current questions; listed so the schema has room.

Gating
------

nano-ros is Rust, so the ``#if defined(CONFIG_TRACING_CTF)`` approach used in
``trace_marker.hpp`` does not apply. The gate is a **Cargo feature**, so the
call site is eliminated entirely when disabled.

.. warning::

   Do not implement this on the ``tracing`` crate facade without also
   compiling it out. A no-op subscriber still costs span construction and a
   level check on **every dispatch**. That needs the ``max_level_off``
   feature to actually vanish. A plain feature gate is the safer shape.

Transport on Zephyr reuses what already exists: the out-of-tree ``app_marker``
CTF event (``patches/zephyr/0002``), which ``scripts/parse-zephyr-ctf.py``
already decodes. No new patch is required.

**Core must not name Zephyr**, and the binding does not go where an earlier
revision of this document said it did. Three corrections from phase-8 W3/W4
investigation:

* ``nros-board-zephyr``'s **Rust half is not in the ASI link graph.** Only its
  ``c/zephyr_run_tiers.c`` is compiled in (``zephyr/CMakeLists.txt:118``); the
  crate sits outside the Cargo workspace and is consumed only by pure-Rust
  Zephyr entry crates. A Rust backend placed there would be unreachable from
  this image.
* ``sys_trace_app_marker`` is an **ASI-local Zephyr patch**, absent from
  ``modules/nros/zephyr/patches/``. nano-ros must therefore never reference the
  symbol, or a non-ASI image fails to link.
* ``nros-node/Cargo.toml`` states the policy outright: the core executor is
  platform-agnostic, "never via a compile-time ``#[cfg(feature =
  "platform-*")]`` branch". A ``zephyr`` feature in core would violate it.

The seam that satisfies all three already exists in the tree as
``wake_probe.rs`` — a probe with hot-path hooks that must vanish in production.
Copy it structurally: a runtime-installed function pointer in an ``AtomicPtr``,
whose C ABI is chosen to *be* the target signature::

    pub type TraceSink = unsafe extern "C" fn(u32, u32);   // == sys_trace_app_marker
    pub fn set_trace_sink(sink: Option<TraceSink>);

Core calls the sink if installed and knows nothing about Zephyr. The Zephyr
side provides a shim in ``modules/nros/zephyr/nros_platform_zephyr_shims.c``
— an unconditional symbol with a Kconfig-gated body, the established idiom
there (cf. ``nros_zephyr_epoch_acquire_configured``)::

    void nros_zephyr_trace_marker(uint32_t marker_id, uint32_t arg) {
    #ifdef CONFIG_TRACING_CTF
            extern void sys_trace_app_marker(uint32_t, uint32_t);
            sys_trace_app_marker(marker_id, arg);
    #endif
    }

That file is already compiled into every Zephyr image, so no CMake source-list
edit is needed. The entry path installs the sink. The dependency stays
one-directional: nano-ros never names an ASI patch.

Feature gating follows the house convention exactly — ``trace-callbacks``,
kebab-case and capability-named, declared ``= []`` in ``nros-node`` and
forwarded through ``nros`` / ``nros-c`` / ``nros-cpp``, each declaration
carrying the mandatory rationale comment. Reaching a Zephyr build is a Kconfig
symbol (``NROS_TRACE_CALLBACKS``) appended to the feature string in
``modules/nros/zephyr/CMakeLists.txt``, with ``CONFIG_NROS_TRACE_CALLBACKS=y``
in this repo's ``tracing.conf`` — which ``build.sh --trace`` already layers, so
no ``build.sh`` change is required.

Confirmed while checking: nano-ros does not use the ``tracing`` crate anywhere
first-party (every hit is in vendored Dust DDS), so adopting the facade would
*introduce* a dependency rather than follow one. The warning above stands
uncontested.

Wire encoding on Zephyr 3.7
---------------------------

``app_marker``'s payload is exactly two ``uint32`` fields, ``(marker_id,
arg)``. Three events, one of them carrying a variable-length name, have to fit
through that. This is the contract between the nano-ros emitter (W4) and the
decoder (W5); the decoder carries the same table in a comment beside the code
that reads it.

=========  ==============  ==================================================
marker_id  event           ``arg``
=========  ==============  ==================================================
16         register        ``handle << 8 | kind``
17         name            the next 4 name bytes, little-endian: byte *i* of
                           the chunk in bits ``8*i``. Repeated until the name
                           is spent, NUL-padded; belongs to the register event
                           it *follows*.
18         start           ``handle``
19         end             ``handle``
=========  ==============  ==================================================

``kind`` is ``0`` timer, ``1`` subscription, ``2`` service, ``3`` action.
Names are truncated at 64 bytes.

Marker ids 1..7 belong to the phase-7 markers and must never be reused —
captured traces carry them, and ``trace_marker.hpp`` warns that renumbering
silently reinterprets every trace taken before it. The block starts at 16
rather than 8 so the phase markers keep room to grow contiguously.

The cost of streaming the name positionally, stated plainly: the name is bound
to its register event by **adjacency, not by handle**, so a dropped or
interleaved event inside a registration burst mis-attributes a name. That is
tolerable only because registration is init-time, once per callback, on one
thread, before any traffic worth measuring — and because a wrong name can never
corrupt a duration, which is keyed on the handle in the runtime events alone. A
capture that starts after init simply has no names, and the decoder falls back
to ``handle N`` labels with the numbers intact.

The alternatives were widening the CTF event, which needs a new Zephyr patch
that W4 exists to avoid, and a compiled-in name table keyed by handle, which is
the hand-maintained registry this phase is removing.

Relationship to the phase markers
---------------------------------

The two layers stay, and they answer different questions:

============================  ==========================================
layer                         question it answers
============================  ==========================================
dispatch hooks (this design)  which callback ran, when, for how long
phase markers (phase-7 W7)    where the time went *inside* one callback
============================  ==========================================

The phase markers are what found the MPC solve and then the duplicated
``setTrajectory``; they are worth keeping. What this design removes is the
hand-placed cycle **enter/exit** pair (``Marker`` values 1 and 2), which the
dispatch hooks supersede exactly.


Overhead
========

Measured against a real capture (phase-7 W12, N=25 loaded ``--drive`` mission,
``tools/rt-eval-traces/phase7-w12-n25-decode.txt``)::

    events the tracer already emits    4437 per control cycle
    app_marker today                    3.5 per cycle  (0.0788 % of 16.3M)
    this design adds                    2   per callback dispatch

For the control callback this is close to net zero, because it retires the two
hand-placed enter/exit markers it replaces — while *gaining* coverage of the
subscription callbacks, which have none today. Registration events fire once at
init, so steady-state cost is zero: that is the init/runtime split earning its
keep, not merely a readability nicety.

.. warning::

   **0.0788 % is a count share, not a time share.** The phase-7 capture
   configuration is ``CONFIG_TRACING_SYNC=y`` with the UART backend, which
   writes inline at the event site, out a serial port. Per-event cost there is
   wildly disproportionate to the count. The per-event cost has **not** been
   measured in isolation on this target, and the count share should not be
   quoted as if it had been.

   That configuration is a measurement rig and must not ship.

Backends, and one trap
----------------------

``CONFIG_TRACING_BACKEND_RAM`` exists on the 3.7 pin, so an in-RAM recorder
needs no new Zephyr patch. Read it before trusting it — it is **fill-once, not
a ring**:

.. code-block:: c

   if (buffer_full) { return; }
   if ((pos + length) > CONFIG_RAM_TRACING_BUFFER_SIZE) {
           buffer_full = true; return;
   }
   memcpy(ram_tracing + pos, data, length);
   pos += length;

It captures the first N bytes and then goes silent permanently. Cheap once
full — a single branch — and useless, which is precisely the wrong trade for a
recorder meant to explain a fault that just happened. A flight recorder needs
overwrite-oldest. ``TRACING_BACKEND_DEFINE`` takes a single ``output``
function, so that is a small addition rather than a fork.

Recommendation: ship gated **off** by default. If it is ever enabled in
production, pair it with an overwrite-oldest RAM backend and measure per-event
cost then, rather than extrapolating from the count share above.


Not chosen, but recorded
========================

``-finstrument-functions`` on the controller translation units
--------------------------------------------------------------

Exactly what Zephyr 4.3 does, and available to us on 3.7 by implementing
``__cyg_profile_func_enter`` / ``__cyg_profile_func_exit`` on top of the
existing ``app_marker`` event. It needs no manual instrumentation at all and
gives a full callgraph *inside* the callback.

Worth stating plainly: **this would have found the duplicated**
``setTrajectory`` **immediately**, and would have given the QP breakdown
directly instead of the two wrong hypotheses that phase 7 spent captures on.

It is not the structural fix, because event volume is already ~200 MB per
mission and instrumenting every function would multiply that. It is the right
*deep-dive* tool: a targeted, short capture over a narrow set of translation
units, using ``-finstrument-functions-exclude-*`` to bound it. Complementary to
the dispatch hooks, not an alternative.

Perfetto export
---------------

``scripts/parse-zephyr-ctf.py`` already decodes the full stream. Emitting
Chrome Trace Event JSON from it is a small addition and buys a real timeline
UI with flame charts — the direction Zephyr upstream took with ``zaru.py``.
Cheap, and independent of everything above.


Exit plan for the out-of-tree patches
=====================================

``patches/zephyr/0002-ctf-app-marker-event.patch`` exists because Zephyr 3.7
has no user-event facility (verified: ``named_event`` is absent from the 3.7
tree). Zephyr 4.3's Instrumentation subsystem supersedes it. When this repo
leaves the 3.7 LTS pin, patch 0002 should be retired rather than forward-ported
— that note belongs in ``patches/zephyr/README.md`` so the patch does not
outlive its reason.


References
==========

* ros2_tracing design — https://github.com/ros2/ros2_tracing/blob/rolling/doc/design_ros_2.md
* ros2_tracing (RA-L 2022) — https://arxiv.org/pdf/2201.00393
* rclcpp executor instrumentation PR — https://github.com/ros2/rclcpp/pull/1738
* Zephyr Instrumentation subsystem — https://docs.zephyrproject.org/latest/services/instrumentation/index.html
* Zephelin (Antmicro) — https://antmicro.com/blog/2025/10/profiling-and-tracing-in-zephyr-with-zephelin
* tokio-console — https://docs.rs/tokio-console/latest/tokio_console/
* CARET — https://github.com/tier4/caret ; in-tree study under ``play_launch/docs/research/caret-analysis.md``
