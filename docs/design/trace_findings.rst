.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

===========================================
What the execution timelines actually showed
===========================================

Analysis of six FreeRTOS captures (mps2-an385 under QEMU, from
nano-ros-rt-eval) and three Zephyr captures (``fvp_baser_aemv8r``, this
repo), all reduced to the common CSV described in :doc:`trace_extraction`
and analysed with ``scripts/analyze-trace-csv.py``.

Read the Zephyr absolute times as model time, not silicon.


Summary
=======

The FreeRTOS tier machinery is exact when the transport is quiet and
collapses by 5x to 10x when it is not. The collapse is a designed
consequence of the priority assignment, and the timing contract does not
express it. The Zephyr lane cannot be compared against any of that, because
its tier threads are not present at all; and the Zephyr statistics published
so far were computed over captures whose first 20 s are boot and warmup.


FreeRTOS
========

Unloaded, the schedule is exact
-------------------------------

Run ``20260807-183424Z``, 247 ms, 693 segments, 96.8% idle:

.. code-block:: text

   task           nominal    period p50   p99      max      exec p50   over 1.5x
   nros_app       1.000 ms   1.000        1.330    1.547    0.010 ms   1/246
   nros_tier@1    5.000 ms   5.000        5.000    5.000    0.011 ms   0/59
   nros_tier@2   10.000 ms  10.000       10.008   10.008    0.026 ms   0/23

Periods land on the nominal value to the microsecond, execution is tens of
microseconds, and preemption is zero on all three tiers. This is what
confirms the 1 kHz / 200 Hz / 100 Hz rates -- measured, not read off a
comment.

Loaded, the 1 kHz tier runs at roughly 200 Hz
---------------------------------------------

Three runs with 4 flood generators (~2000 msg/s inbound):

.. code-block:: text

   run                nros_app period p50   max        over 1.5x nominal
   20260811-021909Z   4.787 ms             5.138 ms    6/7
   20260811-022138Z   4.987 ms             5.153 ms    7/7
   20260811-022203Z   9.647 ms            14.977 ms    3/3

The tier misses four of every five releases, and in one run nine of ten.

**Execution time per activation barely moves** -- 10 us unloaded against 32
to 124 us loaded. The work did not get longer; the task stopped being
released. This is starvation, not overrun, and the distinction matters for
what gets fed back into the contract.

The mechanism is visible in the same table:

.. code-block:: text

   task           occupancy    slice p50    slice max
   zpico_read     72.0-80.8%   616-1097 us  1243 us
   IDLE           10.8-20.1%
   nros_app        1.2-1.5%     26-35 us      91 us

``zpico_read`` holds the core in slices whose median is over half the 1 kHz
period and whose maximum, 1243 us, **exceeds the period outright**. One
transport slice can span an entire release interval of the highest app tier.

This is not a priority inversion
--------------------------------

``src/demo_bringup/system.toml`` puts the app tiers deliberately below the
transport band::

   [tiers.high.freertos]
   priority = 3      # transport band (tcpip_thread, zenoh read/lease,
                     # net poll) is 4

and its comment records why: the previous assignment (5/4/2) sat *on top* of
the transport tasks, the starved RX drain dropped frames, and every publisher
stalled on lwIP retransmission timeouts, giving 1 to 3 s island-wide freezes.
The current ordering is the fix for a worse failure.

So the observation is not a defect to repair. It is a cost to declare:

**The contract states** ``spin_period_us = 1000`` **unconditionally, and that
is false above roughly 750 msg/s inbound.** There is no field expressing a
rate that holds only below an offered-load bound, and this measurement is
what such a field would be populated from.

What these captures cannot support
----------------------------------

The Tonbandgeraet snapshot buffer is 16 KiB. The loaded runs span 32 to 35 ms
and contain 4 to 8 activations of the 1 kHz tier. The direction of the effect
is unambiguous at that sample size; a p99 or a WCET is not. Any percentile
quoted from a loaded FreeRTOS run in this set is three or four samples wide.


Zephyr
======

Whole-capture statistics were measuring boot
--------------------------------------------

On the TAP control capture (``build/zephyr-fvp-tap``, 41587 segments):

* the executor's worst activation gap, 1000.071 ms, occurs at **t = 0.002 s**;
* its longest unbroken slice, 65.324 ms, occurs at **t = 1.028 s**;
* that same 65.3 ms maximum appears in all three Zephyr captures across
  different builds, which makes it a boot constant rather than a control-loop
  event;
* inbound traffic does not start until **t = 20 s** -- rx_q[0] goes from 138
  to 891 segments per 10 s bucket and idle collapses from 8021 ms to 773 ms.

Restricting to the steady state changes every number that matters:

.. code-block:: text

   main (executor)        whole capture      t >= 20 s
   slice p50                 829.5 us         4921.1 us
   slice max               65323.7 us        25907.2 us
   period p50                 6.200 ms          9.742 ms
   period max              1000.352 ms         38.287 ms
   preempted activations       10.9%              6.4%

Both columns are correct arithmetic over their inputs and only the right one
describes anything that runs. Statistics quoted from these captures without a
window are diluted by a 20 s warmup.

Steady-state executor behaviour
-------------------------------

.. code-block:: text

   activations 6582
   period   p50  9.742   p90 19.353   p99 29.173   max 38.287 ms
   exec     p50  6.138   p90 12.832   p99 19.190   max 25.907 ms

The executor runs about 6 ms of work every 10 ms -- a 63% duty cycle, and
68% of all non-idle time on the core. Headroom is thin, and the p99 activation
gap of 29.2 ms is the same order as the 30 ms nominal control period.

The 3.2 s gap is a traffic gap, not a stall
-------------------------------------------

``rx_q[0]`` and the unnamed pool thread at ``0x00281cc0`` both show a maximum
inter-activation gap of 3234 ms, agreeing to 150 us, which looks like a single
global stall. It is not. Over that window the core is **83.9% idle**; the two
threads agree because they are the same RX pipeline and neither had work.
On the FVP that idle is fast-forwarded, so the 3.2 s is not a real duration
either.

No tier threads exist on this lane
----------------------------------

Every thread in the image is either named by this repo
(``asi_thread_stats``, ``asi_sntp_resync``), a Zephyr subsystem thread
(``rx_q[0]``, ``sysworkq``, ``net_mgmt``, ``tcp_work``), or an unnamed
nano-ros **generic pool** thread. The tier pool is absent, so
``[tiers.high.zephyr] priority = 5, deadline_us = 10000`` is not active here
and the control work runs on ``main``.

The consequence for this comparison is blunt: the Zephyr lane and the
FreeRTOS lane are not running the same structure, and no cross-lane tier
number in this document should be read as a like-for-like comparison.

The priority experiment is inconclusive by construction
--------------------------------------------------------

Captures ``w7_0`` and ``prio`` agree on 91.17% of rows byte-for-byte and on
every distribution statistic to 0.1 us, with no Kconfig delta between the
builds. That is not evidence that priority does not matter: in both captures
``rx_q[0]`` has **6 segments over 277 s** and ``main`` holds 99% of non-idle
time. There is nothing to prioritise against. The experiment needs the TAP
profile, where traffic exists.


Cross-lane cautions
===================

**Idle is not comparable.** FreeRTOS idle (10.8% to 20.1% loaded, 96.8%
quiet) is measured; Zephyr idle is fast-forwarded by the model and its 28%
is not a duty cycle. Occupancy on the Zephyr lane must be taken against
``busy_span_us``, which is why ``trace_meta.json`` carries it.

**Sample sizes differ by three orders of magnitude.** Zephyr captures span
65 s of busy time with 41587 segments; loaded FreeRTOS captures span 32 ms
with 117. They answer different questions and neither substitutes for the
other.

**Provenance was lost on both sides.** Four of six FreeRTOS runs carry no
load level, yet ``20260811-021909Z`` is plainly loaded -- ``zpico_read`` at
72%, ``nros_app`` at 4.787 ms -- and had to be classified from its own
numbers. The Zephyr metadata named no source capture, so identifying which of
three candidates produced a given CSV meant re-running the decoder over all
of them. Both writers now record ``source_path``; the FreeRTOS capture recipe
should record its load level unconditionally.


Defect noted in the upstream tooling
====================================

``tools/plot_trace.py:120`` in nano-ros-rt-eval captions every figure
``fixed priorities high=5 mid=4 low=2``. Those are the values ``system.toml``
documents as the old, broken assignment; the current one is 3/2/1. Any figure
published from that script carries a priority caption contradicting the
contract it illustrates. This repo does not use that script.
