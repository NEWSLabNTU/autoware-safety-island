.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

=====================================
Taking the trace tooling to real silicon
=====================================

Notes for the NXP CANHUBK344 lane. :doc:`zephyr_tracing` is the reference for
the subsystem itself; this document is only what changes off the model. Everything in :doc:`trace_extraction` was
built against two simulators, the Arm FVP and QEMU, and some of what those
targets forced is wrong on hardware. This is what transfers, what changes, and
the one thing that will silently corrupt a capture if it is not handled.

The board is in Zephyr 3.7 as ``mr_canhubk3`` (S32K344, Cortex-M7 at 160 MHz,
XIP from flash, 128 KiB + 320 KiB SRAM).


Before anything else: the defaults are wrong for hardware
========================================================

This is reachable without making a single deliberate choice, which is why it
comes ahead of the wrap and the drop counter below.

Zephyr defaults to ``TRACING_ASYNC`` (``subsys/tracing/Kconfig:81``) and
``TRACING_BACKEND_UART`` (``:134``). Both defaults, together, on hardware:

* **Async + UART**, changing nothing, drops events silently into a counter
  that has no reader anywhere in the tree.
* **Sync + UART** -- and sync is the knob a reader is most likely to flip,
  because it sounds like the safer name -- holds interrupts disabled for a
  byte-at-a-time blocking UART write. 1.215 ms per event at 115200. At the
  event rate this repo actually measured, 95x realtime.

So the safer-sounding of the two names is the worse one, and neither default
is usable. Choose the method and the backend together and deliberately, and
state both; the two are one decision, not two. The reasoning is in
`Sync or async decides whether events can vanish`_.


What transfers unchanged
========================

* The CSV contract, ``task,start_us,end_us``, and ``trace_meta.json``.
* ``scripts/analyze-trace-csv.py``. It is lane-agnostic and reads the time
  base out of the metadata rather than assuming one.
* ``scripts/parse-zephyr-ctf.py``, **but pass ``-m``**. It does not read the
  schema from the capture: it parses a TSDL file, defaulting to this repo's
  pinned 3.7 tree. Point it at your own tree's
  ``subsys/tracing/ctf/tsdl/metadata``. Event ids are positions in that file,
  so a mismatched pairing renames events and misreads fields silently instead
  of failing. Note also that this repo's TSDL is patched to add
  ``app_marker``; a stock metadata will not decode the heartbeat.
* The out-of-tree ``app_marker`` event (``patches/zephyr/``) and
  ``common::diag::trace_marker``. Not board-specific.


The 32-bit timestamp wraps every 4.295 s
========================================

This is the one that will bite.

**Verified on both 3.7 and 4.4.0.** The CANHUBK344 lane pins Zephyr 4.4.0,
not the 3.7 this repo uses, so the line was checked in that tree rather than
assumed to carry:
https://raw.githubusercontent.com/zephyrproject-rtos/zephyr/v4.4.0/subsys/tracing/ctf/ctf_top.h
It is identical. It sits behind ``CONFIG_TRACING_CTF_TIMESTAMP``, which is
``default y`` and depends on ``TRACING_CTF``, so it cannot be quietly off
while CTF is on -- losing it takes an explicit ``=n``. Adding the line to a
board ``.conf`` is harmless and unnecessary. The real precondition is one
level up: ``CONFIG_TRACING_CTF`` itself, which a board that has never traced
will not have at all.

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


Sync or async decides whether events can vanish
===============================================

``TRACING_METHOD_CHOICE`` defaults to ``TRACING_ASYNC``, which puts a ring
buffer between the emit site and the backend. Sizing it is a real decision,
and an undersized buffer fails by dropping events rather than by failing to
build.

The two paths differ exactly where it matters. ``ctf_top.h`` emits through
``tracing_format_raw_data``, and:

* **sync** (``tracing_format_sync.c:41``) takes the lock and calls
  ``tracing_buffer_handle`` straight through. **No drop path on the CTF
  route.** The drop calls elsewhere in that file are in
  ``tracing_format_string`` and ``tracing_format_data``, which CTF does not
  use.
* **async** (``tracing_format_async.c:38``) puts into the ring buffer and
  calls ``tracing_packet_drop_handle()`` when the put fails. Events are lost
  whole, so the stream stays well-formed and a decoder sees nothing wrong.

**What SYNC costs is the backend's write, paid with interrupts disabled.**
``TRACING_LOCK()`` is ``irq_lock()`` (``tracing_core.h:17``), so the whole
backend output call runs with interrupts off. That makes the sync/async
question inseparable from the backend choice:

* **RAM** -- a bounded ``memcpy``. Microseconds, interrupts off. Fine.
* **UART** -- ``tracing_backend_uart_output`` is a byte-at-a-time
  ``uart_poll_out`` loop, and ``uart_poll_out`` blocks until the transmitter
  is ready. At 115200 that is 86.8 us per byte, so a 14-byte event holds
  interrupts off for **1.215 ms**. At the TAP capture's 78000 events/s that
  is 95x realtime. Not slow: impossible.
* **SEMIHOST** -- ``semihost_write`` is ``bkpt 0xab``
  (``arch/arm/core/cortex_m/semihost.c``), which halts the core until the
  host probe services it. Once per event, interrupts off. The instrument
  becomes the dominant term.

Semihosting therefore is **not** a third option. Under SYNC its per-event
cost lands inside ``irq_lock``; under ASYNC it avoids that only by moving the
trap to the tracing thread, which is the drop path again. It also makes the
image undeployable standalone: ``bkpt 0xab`` with no probe attached and
servicing semihosting does not degrade, it faults. A safety image that dies
when the debugger is unplugged is a property to justify, not to accept
quietly.

So the choice is not a performance tuning knob, it is a correctness one:

============  ==========================  ================================
              events can be lost          effect on what you measure
============  ==========================  ================================
``SYNC``      no (on the CTF path)        emit blocks on the backend, so
                                          tracing perturbs the timing it
                                          is measuring
``ASYNC``     yes, silently               timing preserved, coverage not
============  ==========================  ================================

This repo's FVP builds set ``CONFIG_TRACING_SYNC=y`` explicitly, overriding
the default, which is why the captures behind :doc:`trace_findings` have no
holes. That was a lucky inheritance rather than a considered choice.

**Do not copy that config to hardware.** It pairs SYNC with
``TRACING_BACKEND_UART``, which survives only because the FVP's UART is
modelled and ``uart_poll_out`` returns in negligible model time. On silicon
the same pair is the 1.215 ms interrupts-off case above. The FVP numbers are
sound for what :doc:`trace_findings` claims about them, and the
*configuration* that produced them is not a hardware template.

**The drop counter cannot be read.** ``tracing_packet_drop_num``
(``tracing_core.c:46``) is a ``static atomic_t``, incremented on every drop
and reset at init. Across the whole Zephyr tree there is no accessor, no
shell command and no reader of any kind. On async, events are lost, the loss
is counted, and the count is unreachable. Anyone running async should plan to
expose it -- a two-line accessor -- rather than assume a well-formed stream
means a complete one.

Async has a second blind spot on the same route: ``tracing_format_async.c:42``
returns early when the caller is the tracing thread, so on async the tracer's
own execution never appears in its own trace.

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
2. **Burst into RAM, read out over the debugger.** A 128 KiB buffer holds
   about 9400 events, which at full rate is only about 120 ms -- the same
   order as the FreeRTOS lane's 16 KiB Tonbandgeraet snapshot, and it carries
   the same warning: see :doc:`trace_findings`, where 4 to 8 activations per
   loaded run established a 5x rate collapse and were nowhere near enough for
   a percentile.

   **The RAM backend is one-shot, not a ring.**
   ``tracing_backend_ram.c`` is a ``memcpy`` into a plain array, and once
   ``pos + length`` would pass the end it latches ``buffer_full`` and records
   nothing further until re-init. So it truncates the tail rather than
   dropping scattered events.

   That is the better failure mode, and worth being explicit about why: a
   prefix is analysable where a hole-riddled stream is not, and unlike the
   async drop counter the truncation is **detectable from the artifact** --
   ``buffer_full`` set, or the dump ending exactly on the buffer boundary.

   Two practical points. ``CONFIG_RAM_TRACING_BUFFER_SIZE`` defaults to 4096,
   about 290 events at 14.0 bytes each, which is useless; choose and state it.
   And dump ``ram_tracing[0 .. pos]``, not the whole array -- ``init``
   zero-fills it, so a full-array dump appends zeros that a decoder will
   count as trailing garbage.
3. **A fast LPUART.** The S32K344 will run well above 115200; whether it
   reaches 10 Mbaud sustained with a host that can absorb it is worth
   measuring before committing to it.

**There is no RTT backend for CTF.** ``TRACING_BACKEND_CHOICE`` offers UART
(default), USB, POSIX, RAM and ADSP_MEMORY_WINDOW, plus SEMIHOST on 4.4 and
later. RTT does appear in the tracing subsystem, but under
``SEGGER_SYSTEMVIEW``, which is a *format* selected instead of
``TRACING_CTF`` -- so taking RTT means giving up CTF and everything in
:doc:`trace_extraction` that decodes it.

Two ways out, both worth knowing before assuming RTT is available:

* ``TRACING_BACKEND_SEMIHOST`` (4.4+, not in 3.7) needs no extra pins on an
  existing SWD setup and has no buffer ceiling. **It is nonetheless
  disqualified** -- see the sync/async section above: the per-event ``bkpt``
  trap is paid with interrupts disabled, and the absent buffer ceiling is not
  the binding constraint. Measuring its throughput would have produced a
  plausible number and missed this entirely.
* An out-of-tree backend via ``TRACING_BACKEND_DEFINE()``. Upstream Zephyr
  hardcodes the backend name in ``tracing_core.c`` and offers no Kconfig to
  select one, so this repo carries
  ``patches/zephyr/0003-tracing-allow-an-out-of-tree-backend.patch`` (16 lines)
  to make it selectable. That patch, not anything upstream, is what an
  RTT-for-CTF backend would need.

.. note::

   Line numbers in this document are from the Zephyr 3.7 tree this repo
   pins. They drift across versions -- ``tracing_packet_drop_num`` is at
   ``tracing_core.c:46`` on 3.7 and ``:30`` on 4.4.0. The code is unchanged;
   cite the tree with the line.

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
