.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

===========================================
Real-time probes and benchmarks in nano-ros
===========================================

This began as a survey of what safety-critical and real-time systems measure,
checked against what nano-ros measured, to find the gaps worth closing. Six
recommendations came out of it. Five have since been built and one turned out
to rest on a false premise.

It is kept as a record of what was built, what each probe actually measures,
and — because two of the original recommendations were wrong in ways that cost
real work — where the survey misled.

Status
======

============================================  ==================================
Item                                          State
============================================  ==================================
1. Release jitter                             Landed; nominal corrected twice
2. Execution-time high-water                  Landed
3. Stack high-water                           Landed; C++ setter in review
4. Alive supervision                          In review (nano-ros #462)
5. Port conformance benchmark                 Landed
6. End-to-end chain latency                   **Withdrawn — premise was wrong**
============================================  ==================================

Phase-436 later added two more, from a review of the executor rather than of
the field: park-deadline attribution and a declared park granularity. They are
described under `What phase-436 added`_.


Two corrections
===============

These are stated first because both cost work, and both are the same kind of
error: a claim about the system that nobody checked against the system.

Recommendation 6's premise was false
------------------------------------

The original text said chain latency was *"the largest item here and the only
one that touches the wire format"*, and listed it as highest value and highest
cost.

**No wire-format change is needed, and none was needed when this was written.**
``max-age-runtime`` already computes age from the CDR header stamp
(``observe_publish_stamp``, ``monitor.rs:116``). If a publisher propagates the
originating stamp rather than restamping, that age *is* sensor-to-actuator
latency across the chain — the quantity the recommendation asked for.

The real gap was never the wire format. It is **stamp-propagation discipline**:
whether each node in a chain forwards the stamp it received. That is a
convention to document and check, not a protocol change, and it is a far
smaller piece of work than the one that was scheduled.

The recommendation is withdrawn rather than deferred, because deferring it
would preserve the wrong reason.

Recommendation 1 was implemented on a path no image takes
---------------------------------------------------------

The shape given was *"on each activation, record ``actual_release -
nominal_release``"*, which is correct. The first implementation (nano-ros
#312) put the probe in ``spin_period``.

**nros-cpp's tiers do not call ``spin_period``.** They run a ``spin_once`` loop
paced by ``platform_sleep_us``, so the probe recorded zero forever while
appearing to work. This is the same class as nano-ros issue 0736 — a
measurement placed on a path no shipped image takes — which had already been
cited in the very PR that made the mistake.

Fixed in #379/#418 by moving the probe into ``spin_once``, the function every
driver goes through.

A second, subtler version of the same error survived that fix. ``spin_once``'s
argument is a **blocking bound**, not a cadence, and the tier loops pass a
hardcoded 10 ms while pacing themselves with ``platform_sleep_us``. So the rule
judged every tier against 10 ms whatever ``spin_period_us`` the contract
declared: a 1 kHz tier could run nine periods late and register as on time.
Corrected in #648 by declaring the cadence explicitly
(``set_spin_nominal_us``) instead of inferring it from the timeout.

The lesson worth keeping: **for a probe, "it compiles and reports a number" is
not evidence that it measures the intended thing.** Three separate reviews
passed a probe that was reporting zero.


What was built
==============

1. Release jitter
-----------------

``release-jitter-runtime`` (``monitor.rs:563``), backed by
``Executor::release_jitter() -> (max_us, late_wakes, total_wakes)``.

Records ``actual - nominal`` per wake in ``spin_once``. The maximum is the
figure of merit, as in ``cyclictest``; the late/total ratio separates the two
failure modes — one late wake in ten thousand is a glitch, ten thousand in ten
thousand means the period cannot be met at all.

**Why it mattered here.** The ASI Zephyr capture showed activation periods of
p50 9.742 ms, p99 29.173 ms, max 38.287 ms against a nominal 30 ms. Getting
that number required a full CTF capture, an out-of-tree kernel patch and a
decoder. The probe reports it directly on any target with no tracing at all.

2. Execution-time high-water
----------------------------

``SchedContext::max_exec_us`` (``sched_context.rs:273``), a retained
``fetch_max`` on a value the dispatch loop already computed and discarded.

The point is evidence produced **when nothing is violated**. ``Violation.measured``
records a number only at the instant a bound breaks, so a system that never
violates produced no evidence of how close it came — which is exactly what
sizing ``budget_us`` and ``deadline_us`` needs. Measured maxima now flow back
into ``system.toml`` rather than being guessed and then policed.

**Execution and response time are kept apart, deliberately.** The ASI analysis
found a callback whose execution max was 226.969 ms while its wall-clock span
was 393.510 ms. Reporting only the span would have blamed the callback for
167 ms of other threads' work. Budget is sized from execution; deadline is
checked against response.

3. Stack high-water
-------------------

``nros_platform_task_stack_unused_bytes`` (``platform.h:292``) and the
``stack-headroom-runtime`` rule.

Replaces a Zephyr-only workaround: ASI had been scraping ``thread_analyzer``
printk output and grepping it in CI. ISO 26262 treats spatial freedom from
interference as first-class, and stack overflow is the classic way one
component corrupts another.

One defect worth recording, because it was self-inflicted and both PRs missed
it: the accessor was first placed inside an ``alloc``-gated ``task`` module and
called unconditionally, which broke the ``no_std`` Zephyr build. Neither PR
caught it because ``--features std`` implies ``alloc``. Moved to the crate root
in #487.

The C++ setter (``nros_cpp_executor_set_min_stack_headroom``) is nano-ros #529,
in review. Wiring it on the ASI side is still open.

4. Alive supervision
--------------------

nano-ros #462, in review.

Every other monitor fires when something *happens*. Nothing fires when a
callback stops happening altogether — ``rate-hierarchy-runtime`` covers
publishers, not callbacks, so a timer callback that silently stops while its
publisher is driven from elsewhere is invisible.

AUTOSAR's Watchdog Manager separates these deliberately: *alive supervision*
(did it run at all) is a distinct mechanism from *deadline supervision* (did it
finish in time). nano-ros had the second and not the first.

5. Port conformance benchmark
-----------------------------

``packages/testing/nros-bench/port-metric``, a small ``no_std`` crate run per
port.

Measured on the POSIX port: allocate+free 218 M/s, yield 13.7 M/s, mutex
lock/unlock 252 M/s. The value is not the absolute number, which is
board-specific, but the regression signal and an honest cross-port table.

Shaped after EEMBC Thread-Metric, whose tests map nearly one-to-one onto what
a nano-ros port must provide:

===========================  ==========================================
Thread-Metric test           nano-ros port surface
===========================  ==========================================
Cooperative context switch   ``task_init`` / yield
Preemptive context switch    ``task_init`` with priorities
Interrupt processing         ISR to task wake
Interrupt + preemption       wake causing a switch
Message passing              the RMW take/publish path
Semaphore processing         ``nros_platform_mutex_*`` / wake
Memory alloc/dealloc         ``nros_platform_alloc``
===========================  ==========================================


.. _What phase-436 added:

What phase-436 added
====================

A later review of the executor itself — rather than of the field — found that
the blocking wait was bounded by the caller's timeout narrowed only by the
*backend's* next event. Nothing let a registered **timer** shorten the sleep,
so ``spin_default()``'s 50 ms slept past a 10 ms timer it owned.

Two probes came out of the fix, both reporting rather than judging:

* **Park attribution** — which deadline source bounded each park
  (``last_park() -> (bound_us, WakeSourceId)``). Turns "why did we wake" from a
  guess into a number, for one byte per spin.
* **Declared park granularity** — ``park_granularity_us()`` states what the
  build can actually express (1 ms today, since every ``nros_platform_wake_*``
  port takes ``uint32_t timeout_ms``), and
  ``release_jitter_granularity_us()`` states what the jitter figure is
  therefore worth.

The second exists because of a discipline this document has now been wrong
about twice: **a measurement must not claim precision its mechanism cannot
deliver.** Jitter is reported in microseconds; whether that is honest depends
on whether the loop paces itself or is paced by the wait, so the executor says
which.

See nano-ros ``docs/roadmap/phase-436-poll-wake-revision-deadline-driven-executor.md``.


Not recommended
===============

* **A Rhealstone-style single composite figure.** It collapses six independent
  costs into one number that hides which of them regressed. Thread-Metric's
  per-test breakdown is strictly more useful.
* **Anything requiring a cycle-accurate model to interpret.** The FVP is a
  programmer's-view fast model; probes whose value depends on cycle counts will
  produce confident nonsense there. Everything above is meaningful on a
  functional model and sharper on silicon.


Still open
==========

* Alive supervision (nano-ros #462) and the C++ stack-headroom setter (#529)
  are in review; wiring the latter into ASI's entry has not been done.
* **Stamp-propagation discipline** — the real content of the withdrawn
  Recommendation 6. Whether each node in a chain forwards the stamp it
  received is unchecked, and until it is, ``max-age-runtime`` reports
  end-to-end latency only where the convention happens to hold.
* Making the executor's wait loops wake off the backend's listener rather than
  a fixed 10 ms grid (nano-ros issue 1195's larger half).


Sources
=======

* EEMBC / Express Logic Thread-Metric Benchmark Suite --
  https://www.embedded.com/measure-your-rtoss-real-time-performance/
* cyclictest / rt-tests, latency histogram and maximum-latency methodology --
  https://documentation.ubuntu.com/real-time/latest/how-to/measure-maximum-latency/
* AUTOSAR timing protection and execution budgets for ISO 26262
  mixed-criticality --
  https://www.embedded.com/apply-autosar-timing-protection-to-build-safe-and-efficient-iso-26262-mixed-criticality-systems/
* AUTOSAR functional safety measures, Watchdog Manager alive and deadline
  supervision --
  https://www.autosar.org/fileadmin/standards/R22-11/CP/AUTOSAR_EXP_FunctionalSafetyMeasures.pdf
* ros2_tracing, instrumentation overhead and latency decomposition --
  https://arxiv.org/abs/2201.00393
* REP-2014, benchmarking performance in ROS 2 --
  https://ros.org/reps/rep-2014.html
