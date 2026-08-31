.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

=============================================
Probes and benchmarks worth adding to nano-ros
=============================================

A survey of what practical safety-critical and real-time systems measure,
checked against what nano-ros measures today, to find the gaps worth closing.

Each recommendation names what nano-ros already has, so nothing here proposes
rebuilding something that exists.


What nano-ros already has
=========================

Verified in the tree, not assumed.

**Contract** (``nros-platform/src/board/tier.rs:45``): ``priority``, ``core``,
``class``, ``period_us``, ``budget_us``, ``deadline_us``, ``deadline_policy``,
``preempt_threshold``, ``time_slice_us``, ``stack_bytes``, ``spin_period_us``.

**Runtime monitors** (``nros-node/src/executor/monitor.rs``), drained into
``nros-diagnostics``:

* ``rate-hierarchy-runtime`` -- publish rate over a window
* ``max-age-runtime`` -- subscriber take age from the CDR header stamp
* ``max-latency-runtime`` -- node-path take-to-publish
* ``timer-overrun-runtime`` -- exact, from the timer's own counter
* ``deadline-miss-runtime`` -- callback ran past its SchedContext deadline

**Sporadic server** budget replenishment (``sched_context.rs``).

**Heap accounting** with a retained high-water: ``peak_bytes``
(``nros-platform/src/lib.rs:219``), exposed as
``nros_platform_heap_used_bytes``.

**Callback-level CTF tracing**, 30 leaf dispatch sites (nano-ros PR #145).

**A static spin-quantization audit** (``spin.rs``, issue #515) that warns when
a declared period is not an integer multiple of the spin period.

That is a strong base. The monitors are event-driven violation detectors and
the contract is rich. What is thin is *evidence produced when nothing is
violated*, which is what sizing a contract needs.


Recommendation 1: release jitter
================================

**The gap nano-ros already names.** ``spin.rs:2077``:

    ...the rate is preserved and no activation is dropped, so every runtime
    rule is (correctly) silent -- the jitter stays invisible until someone
    measures cadence on target.

Issue #515 added a *static* audit for the one cause it could see at build
time. Nothing measures actual release instants at runtime.

This is the single most established probe in the field. ``cyclictest``, the
reference tool for real-time Linux validation, exists to report exactly one
thing: the deviation between a timer's programmed wake-up and the instant the
task actually resumed, as a histogram whose **maximum** is the figure of merit.
Every RT Linux distribution documents it as the primary acceptance measurement.

**Shape:** on each activation, record ``actual_release - nominal_release``.
Keep min / max / a coarse histogram per tier. Cheap: one clock read that the
spin loop already performs, one subtraction, one ``fetch_max``.

**Why it matters here:** the ASI Zephyr capture showed an executor whose
activation period had p50 9.742 ms, p99 29.173 ms and max 38.287 ms against a
nominal 30 ms control period. Reconstructing that needed a full CTF capture,
an out-of-tree kernel patch and a decoder. A jitter histogram would have said
it directly, on any target, with no tracing infrastructure at all.


Recommendation 2: execution-time high-water
===========================================

``SpinPeriodResult.elapsed`` (``types.rs:99``) is per-period and transient.
``Violation.measured`` records a number only at the instant a bound is
breached. So a system that never violates produces **no evidence of how close
it came**, which is precisely the evidence needed to choose ``budget_us`` and
``deadline_us``.

AUTOSAR OS assigns each task an execution budget and terminates a task that
exceeds it. That mechanism is only as good as the budget, and the budget comes
from measured worst-case execution on target.

**Shape:** retain a per-callback (or per-SchedContext) ``exec_max_us``,
alongside a ``since`` marker so it can be read and reset. Optionally a small
histogram. This is one ``fetch_max`` on a value the dispatch loop already
computes.

**Payoff:** closes the loop the contract implies but cannot currently feed.
Measured maxima flow back into ``system.toml`` as budgets, rather than being
guessed and then policed.

Pair it with **execution vs response time** kept apart. The ASI Zephyr
analysis found a callback whose execution max was 226.969 ms while its
wall-clock span was 393.510 ms; reporting only the latter would have blamed
the callback for 167 ms of other threads' work. Budget is sized from
execution; deadline is checked against response.


Recommendation 3: stack high-water
==================================

Heap has ``peak_bytes``. **Stack has nothing portable** -- the only stack call
in the tree is Zephyr's ``k_thread_stack_free`` on teardown.

ISO 26262 treats spatial freedom from interference as a first-class
requirement, and stack overflow is the classic way one component corrupts
another's state. AUTOSAR pairs memory protection with stack monitoring for
exactly this reason.

The absence shows: ASI had to read Zephyr's ``thread_analyzer`` printk output
and grep it in CI (``require_stack_headroom`` in ``.github/scripts``). That is
a text-scraping workaround for a missing platform capability, and it is
Zephyr-only.

**Shape:** add ``nros_platform_task_stack_high_water(task) -> usize`` to the
platform ABI. Every target kernel already supports it:

* FreeRTOS -- ``uxTaskGetStackHighWaterMark``
* Zephyr -- ``k_thread_stack_space_get``
* ThreadX -- stack fill-pattern inspection (``tx_thread_stack_highest_ptr``)
* POSIX -- pattern fill at spawn

Ports that genuinely cannot report it return ``None``, which is the same
"unsupported is explicit" discipline the ABI already applies to ``stack_bytes``
and ``priority``.


Recommendation 4: alive supervision
===================================

Every current monitor fires when something happens: a rate drifts, an age
exceeds, a deadline is missed. Nothing fires when a callback **stops happening
altogether**. ``rate-hierarchy-runtime`` covers publishers, not callbacks, so
a timer callback that silently stops firing while its publisher is driven from
elsewhere is invisible.

AUTOSAR's Watchdog Manager separates these deliberately: *alive supervision*
(did it run at all, at roughly the right rate) is a distinct mechanism from
*deadline supervision* (did it finish in time). nano-ros has the second and
not the first.

**Shape:** per-SchedContext liveness counter with an expected activation count
per window; a violation when the delta is zero or far under. Reuses the
existing window drain and the ``DeadlineAction`` escalation ladder
(``ignore`` / ``warn`` / ``skip`` / ``fault``), so no new policy surface.


Recommendation 5: a port conformance benchmark
==============================================

nano-ros supports at least Zephyr, FreeRTOS, ThreadX, NuttX, POSIX and several
bare-metal boards. There is no way to say what a port costs, or to notice when
a port regresses.

The EEMBC **Thread-Metric** suite is the established shape for this and has
been the standard RTOS comparison for two decades. Its tests map almost
one-to-one onto what a nano-ros port must provide:

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

**Shape:** one small ``no_std`` crate run per port in CI, reporting
iterations/second per test. The value is not the absolute number, which is
board-specific, but the regression signal and the honest cross-port table.

This also gives a home for the **tracing overhead** number. ``ros2_tracing``
publishes its instrumentation cost (about 0.0033 ms average added end-to-end
message latency) and that published figure is why people are willing to leave
it enabled in production. nano-ros's callback hooks should be able to make the
same claim with the same kind of evidence.


Recommendation 6: end-to-end chain latency
==========================================

``max-latency-runtime`` measures take-to-publish **within one node**. The
quantity a vehicle integrator cares about is sensor-to-actuator across a chain
of nodes.

``ros2_tracing`` separates intra-node, inter-node and end-to-end latency for
this reason, and REP-2014 is the ROS 2 community's attempt to standardise
benchmarking around it.

**Shape:** propagate a correlation id in the message header and record
first-publish and final-consume. This is the largest item here and the only
one that touches the wire format, so it is listed last deliberately. It is
also the only one that answers the question a safety case actually asks.


Not recommended
===============

* **A Rhealstone-style single composite figure.** It collapses six
  independent costs into one number that hides which of them regressed.
  Thread-Metric's per-test breakdown is strictly more useful.
* **Anything requiring a cycle-accurate model to interpret.** The FVP is a
  programmer's-view fast model; probes whose value depends on cycle counts
  will produce confident nonsense there. Everything above is meaningful on a
  functional model and sharper on silicon.


Priority
========

1. Execution-time high-water (Rec 2) -- smallest change, feeds the contract
   directly, and the contract already has the field waiting for it.
2. Release jitter (Rec 1) -- closes a gap the code names, cheap, and needs no
   tracing infrastructure.
3. Stack high-water (Rec 3) -- safety-standard staple, currently worked around
   with a Zephyr-only text scrape.
4. Alive supervision (Rec 4) -- reuses the existing window and escalation.
5. Port benchmark (Rec 5) -- separable, no runtime cost.
6. Chain latency (Rec 6) -- highest value, highest cost, touches the wire.

The first three are all "retain a maximum on a value that is already
computed and then discarded".


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
