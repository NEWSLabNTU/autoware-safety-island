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
``modules/nros/packages``. The dispatch boundary is already a single, narrow
surface, which is what makes this cheap:

* ``executor/dispatcher.rs`` declares the trait — 22 lines, one method::

     /// Drain `ready` and fire each callback. Returns aggregate counts
     fn dispatch<R: ReadySet>(&mut self, ready: &mut R, delta_ms: u64)
         -> SpinOnceResult;

* ``executor/spin.rs`` implements it, and already carries a per-callback
  identity: ``dispatch_callback(&mut self, cb_id: &str, ctx: *mut c_void)``
  alongside a ``DispatchSlot`` type.
* ``nros-c/src/executor.rs`` is a thin wrapper that "delegates all dispatch
  logic to an internal" executor, and already maintains an ``in_dispatch``
  reentrancy flag across ``spin_once`` — i.e. the boundary is already a
  meaningful, named concept in the code.

So the hook is a pair of calls around the per-callback fire inside the
``Dispatch`` implementation, keyed on the identity that is already threaded
through it. No new bookkeeping.

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
