.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

=====================================
Taking the trace tooling to real silicon
=====================================

Notes for the NXP CANHUBK344 lane. Everything in :doc:`trace_extraction` was
built against two simulators, the Arm FVP and QEMU, and some of what those
targets forced is wrong on hardware. This is what transfers, what changes, and
the one thing that will silently corrupt a capture if it is not handled.

The board is in Zephyr 3.7 as ``mr_canhubk3`` (S32K344, Cortex-M7 at 160 MHz,
XIP from flash, 128 KiB + 320 KiB SRAM).


What transfers unchanged
========================

* The CSV contract, ``task,start_us,end_us``, and ``trace_meta.json``.
* ``scripts/analyze-trace-csv.py``. It is lane-agnostic and reads the time
  base out of the metadata rather than assuming one.
* ``scripts/parse-zephyr-ctf.py``. It reads the TSDL out of the capture, so a
  different board's event set decodes with no changes.
* The out-of-tree ``app_marker`` event (``patches/zephyr/``) and
  ``common::diag::trace_marker``. Not board-specific.


The 32-bit timestamp wraps every 4.295 s
========================================

This is the one that will bite.

**Verified on both 3.7 and 4.4.0.** The CANHUBK344 lane pins Zephyr 4.4.0,
not the 3.7 this repo uses, so the line was checked in that tree rather than
assumed to carry:
https://raw.githubusercontent.com/zephyrproject-rtos/zephyr/v4.4.0/subsys/tracing/ctf/ctf_top.h
It is identical. On 4.4.0 it also sits behind ``CONFIG_TRACING_CTF_TIMESTAMP``;
with that off there is no timestamp in the stream at all, which is a different
failure worth checking for first.

``subsys/tracing/ctf/ctf_top.h`` emits

.. code-block:: c

   const uint32_t tstamp = k_cyc_to_ns_floor64(k_cycle_get_32());

The cycle counter is converted to **nanoseconds and then truncated to 32
bits**, so the timestamp wraps every 4.295 s on *every* target regardless of
clock rate. Do not reason from the counter width: at 160 MHz
``k_cycle_get_32()`` wraps every 26.8 s, but that is not the number that
matters, because the nanosecond truncation happens first.

The decoder unwraps by adding 2^32 whenever it sees a large backward step.
That reconstruction is only correct if events keep arriving. An observed gap
of ``g`` could equally be ``g``, ``g + 4.295 s`` or ``g + 8.59 s``, and
nothing in the stream distinguishes them; the decoder always assumes the
smallest. **A quiet stretch longer than 4.295 s silently loses whole epochs**,
and every timestamp after it is wrong by a multiple of 4.295 s.

``parse-zephyr-ctf.py`` now reports this. Every run prints either

.. code-block:: text

   [wrap] no inter-event gap exceeds 2.147 s; unwrapping unambiguous.

or a warning naming every offending gap, with how many epochs the decoder
assumed (always zero) against how many are consistent with the stream. The
same list is written to ``trace_meta.json`` as ``wrap_ambiguous_gaps``, so a
consumer can decide gap by gap instead of trusting or discarding a whole
capture. Check the verdict before trusting any absolute time. Our own FVP
captures pass it, so the analysis in :doc:`trace_findings` is unaffected.

**The fix is a heartbeat, and it must carry a sequence number.** Emit an
``app_marker`` from a periodic thread at 1 s or so, with a monotonically
increasing counter in its ``arg``.

The period alone only *prevents* ambiguity, by ensuring no gap is long enough
to hide a rollover. The counter additionally *repairs* it: elapsed time
between two heartbeats is then known independently of the timestamp, so a
reconstruction that came out short by a multiple of the wrap period is missing
exactly that many epochs and the shortfall says how many. Without the counter
a capture that goes quiet is unusable; with it the capture is recoverable.

.. code-block:: console

   $ python3 scripts/parse-zephyr-ctf.py trace.ctf --csv run/trace.csv \
         --wall-clock-valid --lane zephyr-mr-canhubk3 --heartbeat 8:1000000

``--heartbeat ID:PERIOD_US``. Corrections are reported and recorded in
``trace_meta.json`` as ``heartbeat_corrections``. The comparison is against
the previous heartbeat rather than the first, so only one interval's jitter
has to stay under 2.147 s; drift against a fixed origin would eventually
invent corrections.

A quiet control lane on real hardware is exactly the case that needs this. On
the FVP the core is rarely idle that long. On a target whose nodes are
event-driven off CAN traffic, quiet stretches past 4.295 s are the normal
state rather than the exception, and a capture taken while nothing is faulting
is nearly all gap.


Declare the time base
=====================

The FVP's counter advances during WFI at a rate unrelated to the tick clock,
so its first-to-last span is not elapsed time, and slices spanning an idle
rollover have to be discarded. **Neither is true on silicon.** Both behaviours
used to be hardcoded; they are now a stated property of the target:

.. code-block:: console

   $ python3 scripts/parse-zephyr-ctf.py trace.ctf --csv run/trace.csv \
         --wall-clock-valid --lane zephyr-mr-canhubk3

``--wall-clock-valid`` marks the span usable, stops discarding idle-spanning
slices, and sets ``nonmonotonic_policy: none``. ``--lane`` labels the capture
so a consumer can tell silicon from a model without being told.

Getting this wrong is quiet in both directions. Omitting the flag on hardware
makes the analyser divide by busy time instead of wall time, dropping idle
from the picture and inflating every occupancy. Setting it on an FVP capture
restores a denominator that is not elapsed time. Neither produces an error,
and on a loaded capture the two differ by only about 1.3x, which is small
enough to look plausible.

If ``segments_dropped_counter_jump`` is non-zero on a hardware capture,
something is wrong -- a corrupted stream or a missed wrap -- rather than
normal. On the FVP it is routine.


Transport is the real constraint
================================

Our TAP capture was 91933547 bytes, 6545980 events, 14.0 bytes per event, at
about 78000 events/s. That is **1.09 MB/s sustained**, which needs roughly
10.9 Mbaud. A 115200 console would take 2.2 hours to drain a 84 s capture and
cannot keep up live.

So a UART console backend is not a plan for a full-rate capture. The options,
roughly in order of effort:

1. **Cut the event set.** ``CONFIG_TRACING_*`` selects families. Most of that
   1.09 MB/s is thread switches and ISRs; if the question is control-loop
   cadence, ``app_marker`` plus thread switches is a fraction of it.
2. **Burst into RAM, read out over the debugger.** With roughly 448 KiB of
   SRAM on the S32K344, a 128 KiB buffer holds about 9400 events, which at
   full rate is only about 120 ms. That is the same order as the FreeRTOS
   lane's 16 KiB Tonbandgeraet snapshot (32 to 250 ms), and it comes with the
   same warning: see :doc:`trace_findings`, where 4 to 8 activations per
   loaded run were enough to establish a 5x rate collapse and nowhere near
   enough for a percentile.
3. **A fast LPUART.** The S32K344 will run well above 115200; whether it
   reaches 10 Mbaud sustained with a host that can absorb it is worth
   measuring before committing to it.

Combining 1 and 2 is usually what makes a capture window long enough to be
interesting.


What our numbers are worth to you
=================================

Treat every absolute time in :doc:`trace_findings` as model time. The FVP is a
programmer's-view fast model, not cycle-accurate; the QEMU FreeRTOS lane is
not silicon either. What does transfer is the *shape* of the findings and the
method:

* The FreeRTOS tier rates were exact when quiet (1.000 / 5.000 / 10.000 ms)
  and collapsed by 5x to 10x under a 2000 msg/s flood, because the transport
  band sits above the app tiers by design. That priority relationship is in
  ``system.toml`` and is not a property of the simulator.
* Statistics over a whole capture were dominated by boot and warmup. Window
  the steady state (``analyze-trace-csv.py --since``) before quoting anything.
* Record provenance in ``trace_meta.json`` at capture time. Four of six
  inherited FreeRTOS runs had lost their load level and had to be classified
  from their own numbers.

Your lane is the first one where the absolute numbers will mean something, and
where a WCET is worth measuring rather than approximating.


If you go the FreeRTOS route instead
====================================

``scripts/trace2csv-freertos.py`` and the Tonbandgeraet procedure apply to a
Cortex-M7 target, but note the gap recorded in :doc:`trace_extraction`: only
``nros-board-mps2-an385-freertos`` carries a ``trace/`` config directory. The
an536 and s32z2 boards have none, and a CANHUBK344 board would need one
ported before any of that runs.

To be clear about which tree that is: ``trace/`` is a directory in the
**nano-ros board package** (``modules/nros/packages/boards/...``), holding
``tband_config.h``, ``tband_port.h`` and ``trace_dump.c``. It is not a Zephyr
board directory and there is nothing to look for under ``zephyr/boards/``.
It matters only on the FreeRTOS route; the Zephyr CTF route above needs
nothing of the kind.
