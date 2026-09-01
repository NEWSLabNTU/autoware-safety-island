.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

==========================================
Extracting an execution timeline, either lane
==========================================

Both targets can produce a per-task execution timeline, and both now emit it
in the same shape, so one analyser serves both and the numbers are directly
comparable. This document is the procedure; the analysis of what the captures
actually showed is in :doc:`trace_findings`.

For how the Zephyr tracing subsystem itself is put together -- formats,
methods, backends, and why those three are one decision rather than three --
see :doc:`zephyr_tracing`. Taking this to real hardware needs a few of these
assumptions revisited; see :doc:`trace_on_hardware` for the CANHUBK344 lane.

The extraction machinery on the FreeRTOS side is taken from
`NEWSLabNTU/nano-ros-rt-eval <https://github.com/NEWSLabNTU/nano-ros-rt-eval>`_,
whose ``tools/trace2csv.py`` is carried here as
``scripts/trace2csv-freertos.py``. Its plotting is deliberately **not**
carried over.


The interchange format
======================

``trace.csv`` -- one row per contiguous execution segment on one core::

    task,start_us,end_us
    main (0x00286d80),41562.300,41563.129

A *segment* is an uninterrupted stretch of one thread on the core. Several
consecutive segments of the same thread separated by short gaps are one
*activation* that was preempted; ``scripts/analyze-trace-csv.py`` coalesces
them with a 200 us threshold, which sits well below every period in play
(1 ms on the FreeRTOS high tier, 6 ms on the Zephyr executor).

``trace_meta.json`` sits beside it and carries what the CSV cannot:

``lane``, ``source``, ``source_path``
   Provenance. Record it. Four of the six FreeRTOS runs inherited from the
   eval repo carry no load level, and one of them shows an unmistakable
   loaded signature that had to be reconstructed from its own numbers.

``wall_clock_span_valid``
   Whether ``last_end - first_start`` is elapsed time. **False on the Zephyr
   FVP lane.** The model fast-forwards through WFI while ``CNTVCT`` keeps
   advancing, so that span includes idle stretches that never happened at
   that rate. True on the FreeRTOS lane, whose fold hands over between tasks
   with no gaps and whose timestamp is a real tick counter.

``busy_span_us``
   Sum of non-idle segments, to use as the occupancy denominator when the
   wall span is invalid. On the TAP capture the two differ by 1.3x --
   84063 ms against 65284 ms -- which is small enough to produce
   plausible-looking wrong percentages rather than obviously absurd ones.

``nonmonotonic_policy``
   ``drop`` on Zephyr (a backward counter step discards the segment),
   ``clamp`` on FreeRTOS (the port timestamp can step back a few us across a
   tick boundary; stream order is authoritative, so it is clamped forward).


Zephyr FVP
==========

Requires the out-of-tree CTF patches under ``patches/zephyr/`` and a build
with ``CONFIG_TRACING_CTF``; see :doc:`rt_evaluation_zephyr`.

.. code-block:: console

   $ ./build.sh                       # CONFIG_TRACING_CTF profile
   $ scripts/run-tap-demo.sh          # writes build/<variant>/trace.ctf
   $ python3 scripts/parse-zephyr-ctf.py build/zephyr-fvp-tap/trace.ctf \
         --csv /tmp/run/trace.csv

``--csv`` writes ``trace.csv`` and ``trace_meta.json`` together.

**The stream does not carry its own schema.** A Zephyr CTF capture is bare
event records; the TSDL that names them lives in the tree, at
``subsys/tracing/ctf/tsdl/metadata``, and the decoder defaults to the pinned
one (``-m`` overrides). The pairing is load-bearing and unchecked: event ids
are positions in that file, so decoding a stream against a different tree's
TSDL silently renames events and misreads fields rather than failing. Decode
with the metadata from the tree that built the image.

This repo's copy is also patched -- ``patches/zephyr/0002`` adds the
``app_marker`` event -- so a stock metadata cannot decode markers at all, and
a patched image traced against stock TSDL loses them silently.

The TAP profile needs ``sudo scripts/setup-tap.sh`` once and
``scripts/sntp-server.py`` running on 192.168.10.1:12123 -- the image blocks
on SNTP and gives up after about 11 s without it, never reaching the
controller.


FreeRTOS
========

Uses Tonbandgeraet, vendored at
``modules/nros/third-party/tracing/Tonbandgeraet``. Build the decoder once:

.. code-block:: console

   $ cd modules/nros/third-party/tracing/Tonbandgeraet/tools
   $ cargo build --release -p tband-cli

The instrumented image needs ``-DNROS_TRACE=1`` reaching the **kernel**
compile, not only the tband library: ``FreeRTOSConfig.h`` gates
``configUSE_TRACE_FACILITY`` and the trace hooks on it, and without it the
kernel emits no events and ``uxTaskGetTaskNumber`` is undefined at link.

.. code-block:: console

   $ tband=modules/nros/third-party/tracing/Tonbandgeraet/tband/inc
   $ tracecfg=modules/nros/packages/boards/nros-board-mps2-an385-freertos/trace
   $ NROS_TRACE=1 \
     FREERTOS_CFLAGS="-mcpu=cortex-m3 -mthumb -DNROS_TRACE=1 -I$tband -I$tracecfg" \
     cargo build -p freertos_entry --release --target thumbv7m-none-eabi

Run under QEMU with the peer and, for a loaded capture, N flood generators.
The application restarts the snapshot once the nominal regime is reached and
dumps ``trace.bin`` over semihosting into the run directory. Then:

.. code-block:: console

   $ python3 scripts/trace2csv-freertos.py /path/to/rundir

Two limits are structural and bound what any FreeRTOS capture can support:

* The snapshot buffer is 16 KiB, roughly **250 ms of nominal schedule**, and
  far less once loaded -- the loaded runs analysed here span 32 to 35 ms and
  contain 4 to 8 activations of the 1 kHz tier. That is enough to establish a
  rate collapse and nowhere near enough for a percentile or a WCET.
* Only ``nros-board-mps2-an385-freertos`` carries a ``trace/`` config
  directory. The an536 and s32z2 boards, which are what this repo's FreeRTOS
  CI actually runs, have none, so the procedure above does not yet apply to
  them. Porting that directory is the prerequisite for tracing the lane we
  ship.


Analysis
========

.. code-block:: console

   $ python3 scripts/analyze-trace-csv.py /tmp/run
   $ python3 scripts/analyze-trace-csv.py --since 20 /tmp/run   # skip warmup

Per task: occupancy, slice-duration distribution, activation period and
jitter, and what fraction of activations were preempted.

``--since`` matters more than it looks. Every capture here mixes a warmup
with the regime under study, and statistics over the whole span are diluted
by it: on the TAP capture, traffic does not start until t=20 s, and including
the warmup moves the executor's slice p50 from 4.9 ms to 0.8 ms and its worst
activation gap from 38 ms to 1000 ms. Neither whole-capture figure describes
anything that runs.
