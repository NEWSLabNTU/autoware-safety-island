..
 # Copyright (c) 2026, Arm Limited.
 #
 # SPDX-License-Identifier: Apache-2.0

#############################################
Real-time evaluation tooling on Zephyr
#############################################

Study of the mechanisms available for extracting a **task timeline** and
**scheduling statistics** from the safety island's Zephyr target
(``fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp``, Zephyr v3.7.0 LTS, nano-ros
runtime). Written to give the phase-4 rate-profiling work a repeatable
measurement basis instead of ad-hoc ``printk`` timing.

All Kconfig / source claims below were read out of the pinned Zephyr v3.7.0
tree in ``zephyr/`` and the nano-ros checkout in ``modules/nros/``.

Open work, and the campaign this belongs to, are tracked in
``docs/roadmap/phase-7-realtime-evaluation.md``. The largest open item is that
every measurement below was taken on an idle system.

.. contents::
   :local:
   :depth: 2


Where the build stands today
============================

Nothing in the Zephyr image is currently instrumented. Verified facts about
the image the FVP lane builds:

.. list-table::
   :header-rows: 1
   :widths: 30 20 50

   * - Property
     - Value
     - Source
   * - Tracing subsystem
     - **off**
     - no ``CONFIG_TRACING*`` in any ASI conf
   * - Thread runtime stats
     - **off**
     - no ``CONFIG_THREAD_RUNTIME_STATS`` in any ASI conf
   * - Shell
     - **off** (commented out)
     - ``actuation_module/prj_actuation.conf``
   * - SMP
     - **``CONFIG_SMP=y``, 4 CPUs**
     - nano-ros board bundle (see `How the configuration is actually
       assembled`_). The app's ``CONFIG_SMP=n`` is overridden.
   * - Tick rate
     - **1000 Hz — a 1 ms tick**
     - nano-ros bundle ``prj.conf`` sets ``CONFIG_SYS_CLOCK_TICKS_PER_SEC=1000``,
       merged after the board defconfig's 100
   * - Counter
     - ARM generic timer (``CONFIG_ARM_ARCH_TIMER=y``)
     - board defconfig
   * - Spare UART
     - ``uart1`` enabled, unused
     - ``zephyr/boards/arm/fvp_baser_aemv8r/…_aarch64.dts``

Two of these matter more than the rest, and both were established by reading
the built ``.config`` — not by reading the conf files, which give the wrong
answer (see below).

**Four CPUs.** The image is SMP. That is load-bearing for CTF: the tracing
buffer is guarded by a bare ``irq_lock()`` and the CTF event header carries no
CPU id, so a multi-core capture is both unsafe and ambiguous (`Caveats read out
of the source`_).

**1 ms tick against a 30 ms control period.** 30 ticks per period, so tick
quantisation is not on its own a plausible explanation for a control loop
running at the wrong rate.


How the configuration is actually assembled
===========================================

Reading ``build.sh`` alone gives the wrong answer, so this is worth stating
explicitly. ``build.sh`` passes only ``nano_ros_overlay.conf``, the
``boards/*_actuation.conf`` fragment and (with the tracing flags) the tracing
fragments through ``EXTRA_CONF_FILE``. The nano-ros **board bundle** arrives by
a different route: the nros Zephyr module injects it during CMake configure.
The merge order the build itself reports is:

.. code-block:: text

   actuation_module/prj_actuation.conf                         <- CONFIG_SMP=n
   actuation_module/boards/..._smp_actuation.conf
   modules/nros/.../boards/fvp-aemv8r-smp/prj.conf             <- TICKS_PER_SEC=1000
   modules/nros/.../boards/..._aarch64_smp.conf                <- SMP=y, 4 CPUs
   modules/nros/zephyr/snippets/nros-cyclonedds/cyclonedds.conf
   actuation_module/nano_ros_overlay.conf
   actuation_module/boards/..._smp_actuation.conf
   actuation_module/tracing_stats.conf    (--trace-stats / --trace)
   actuation_module/tracing.conf          (--trace)

Later fragments win, so the bundle overrides the app's ``CONFIG_SMP=n`` and the
tracing fragments override everything. Always verify with
``grep CONFIG_<SYM> <build>/zephyr/.config`` rather than by reading conf files.


The mechanisms
==============

A. CTF tracing — the timeline
-----------------------------

Zephyr's own tracing subsystem (``subsys/tracing/``) with the CTF format
backend. This is the only in-tree route that produces a real, per-event
**task timeline**.

**What it records.** 74 event types in
``subsys/tracing/ctf/tsdl/metadata``. The ones that matter here:

* ``thread_switched_in`` / ``thread_switched_out`` — the timeline proper,
  carrying ``thread_id`` and a 20-byte thread name.
* ``thread_ready`` / ``thread_pending`` / ``thread_suspend`` /
  ``thread_resume`` / ``thread_wakeup`` — release and block points, i.e. the
  raw material for response-time and blocking-time analysis.
* ``thread_priority_set``, ``thread_create``, ``thread_name_set``.
* ``isr_enter`` / ``isr_exit`` / ``isr_exit_to_scheduler`` / ``idle``.
* ``timer_init`` / ``timer_start`` / ``timer_stop`` /
  ``timer_status_sync_*`` — the control timer's own kernel-side lifecycle.
* ``semaphore_*`` / ``mutex_*`` — contention, which is what the phase-4
  round-1 single-threaded-executor finding was about.
* **``socket_recvfrom_enter/exit``, ``socket_sendto_enter/exit``, and the rest
  of the socket family** — the DDS path. This is unusually valuable here: the
  nano-ros Cyclone RMW goes through Zephyr's socket layer, so a CTF trace
  shows DDS RX/TX bracketing directly against the control timer's slice,
  without instrumenting nano-ros at all.

**Thread names — with a caveat measured later.** nano-ros names its RT *tier*
threads: ``nros_zephyr_tier_task_create()`` in
``modules/nros/zephyr/nros_platform_zephyr_shims.c:445`` calls
``k_thread_create()`` at the tier's raw priority and then
``k_thread_name_set(tid, name)``. Its *generic* pool threads get no name, and
on the FVP controller build those are the only ones that exist — see
`Capturing the real control loop`_. Expect ``unknown`` rows unless the tier
model is active.

**Configuration:**

.. code-block:: kconfig

   CONFIG_TRACING=y
   CONFIG_TRACING_CTF=y
   CONFIG_TRACING_SYNC=y           # NOT async -- see the warning below
   CONFIG_TRACING_BUFFER_SIZE=16384
   CONFIG_THREAD_NAME=y            # required for the name fields to be populated
   CONFIG_THREAD_MONITOR=y

   # Trim the event set — the socket family alone can swamp the link.
   CONFIG_TRACING_THREAD=y
   CONFIG_TRACING_ISR=y
   CONFIG_TRACING_TIMER=y
   CONFIG_TRACING_SEMAPHORE=y
   CONFIG_TRACING_MUTEX=y
   CONFIG_TRACING_SYSCALL=n

**Two transports, both workable on FVP:**

*UART backend* — ``CONFIG_TRACING_BACKEND_UART=y`` plus a chosen node. The
board already enables ``uart1``, so the trace stream can be kept off the
console:

.. code-block:: dts

   / {
       chosen {
           zephyr,tracing-uart = &uart1;
       };
   };

``board.cmake`` points every FVP PL011 at stdout (``out_file=-``), so the
capture also needs the UART redirected to a file. ``build.sh`` already exports
``ARMFVP_EXTRA_FLAGS`` and ``cmake/emu/armfvp.cmake:69-77`` appends it after
``ARMFVP_FLAGS``:

.. code-block:: sh

   export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS} \
     -C bp.pl011_uart1.out_file=trace.ctf -C bp.terminal_1.start_telnet=0"

.. note::

   Whether a repeated ``-C`` overrides the earlier occurrence or is rejected
   by the model is worth confirming on first use. If the model rejects it,
   drop the ``out_file=-`` pair from a lane-local copy of ``ARMFVP_FLAGS``
   instead.

*RAM backend* — ``CONFIG_TRACING_BACKEND_RAM=y`` with
``CONFIG_RAM_TRACING_BUFFER_SIZE`` (default 4096, far too small; the FVP has
128 MB of DRAM, so 1–4 MB is free). ``subsys/tracing/tracing_backend_ram.c``
exposes a plain global ``uint8_t ram_tracing[]``, dumpable over the gdb stub:

.. code-block:: text

   dump binary memory trace.ctf &ram_tracing (&ram_tracing + pos)

This is the better fit for AVH, where the gdb stub is already the working
channel (``tools/avh/NOTES.md``: stub on port 4000 behind the
``debug_accelerator`` proxy). It is **not** a ring buffer — see
`Caveats read out of the source`_.

**Host side.** ``zephyr/scripts/tracing/parse_ctf.py`` renders a coloured
timeline; it needs the ``bt2`` (babeltrace2) Python bindings. Point either
tool at a directory holding the captured stream plus
``zephyr/subsys/tracing/ctf/tsdl/metadata``:

.. code-block:: sh

   mkdir -p ctf && cp trace.ctf ctf/channel0_0
   cp zephyr/subsys/tracing/ctf/tsdl/metadata ctf/
   ./zephyr/scripts/tracing/parse_ctf.py -t ctf

The same directory opens directly in **Trace Compass** (Eclipse), which is
the right tool for the actual analysis: Control Flow view for the task
timeline, Resources view for the ISR lanes, and XY charts for per-thread
statistics. ``babeltrace2`` also gives a scriptable path for computing
period/jitter histograms.


B. Thread runtime statistics — the numbers
------------------------------------------

Cheap, always-on scheduling accounting. Complements A rather than replacing
it: A tells you *what happened*, B tells you *how much*.

.. code-block:: kconfig

   CONFIG_THREAD_RUNTIME_STATS=y
   CONFIG_SCHED_THREAD_USAGE=y
   CONFIG_SCHED_THREAD_USAGE_ANALYSIS=y   # unlocks current / longest / num_windows
   CONFIG_SCHED_THREAD_USAGE_ALL=y

``CONFIG_SCHED_THREAD_USAGE_ANALYSIS`` is what makes this interesting.
``include/zephyr/kernel/stats.h`` shows the extra fields it adds to
``struct k_cycle_stats``:

.. code-block:: c

   uint64_t total;        /* total usage in cycles                  */
   uint64_t current;      /* cycles in the current scheduling window */
   uint64_t longest;      /* cycles in the LONGEST window            */
   uint32_t num_windows;  /* number of scheduling windows            */

``longest`` is the per-thread worst-case *contiguous* execution slice and
``num_windows`` is the dispatch count — together, a direct read on whether the
control tier is being preempted mid-callback. Read from the app with
``k_thread_runtime_stats_get()`` / ``k_thread_runtime_stats_all_get()``.

**Via the shell** (``CONFIG_SHELL=y`` is already present, commented out, in
``prj_actuation.conf``): ``kernel threads`` prints per thread the state,
priority, stack usage, and — once the options above are set — total /
current / peak / average execution cycles and CPU percentage
(``zephyr/subsys/shell/modules/kernel_service.c:111-165``). ``kernel stacks``
and ``kernel cycles`` are there too. Zero-code, interactive, and it works over
the FVP console.

**Thread analyzer** (``subsys/debug/thread_analyzer.c``) is the printk/log
flavour of the same data plus stack high-water marks, with
``CONFIG_THREAD_ANALYZER_AUTO=y`` +
``CONFIG_THREAD_ANALYZER_AUTO_INTERVAL=<seconds>`` giving a periodic dump with
no app changes. Good for CI: a soak run emits a stats block every N seconds
into the existing log artifact, and the FVP CI script's ``require_marker``
pattern extends naturally to threshold assertions.


C. Application-level timing — targeted numbers
----------------------------------------------

``CONFIG_TIMING_FUNCTIONS=y`` gives ``timing_counter_get()`` /
``timing_cycles_get()`` / ``timing_cycles_to_ns()``.

Note that AArch64 does **not** select ``ARCH_HAS_TIMING_FUNCTIONS`` and ships
no ``arch/arm64/core/timing.c`` — but ``CONFIG_TIMING_FUNCTIONS`` has no
dependency on that symbol, and ``arch/common/timing.c`` provides a generic
implementation over ``k_cycle_get_32()``, which on this board is the ARM
generic timer. So it works; it is simply the same counter you would read
directly. For a period/jitter histogram around the control callback,
``k_cycle_get_32()`` in a small ring buffer is equivalent and has fewer moving
parts.

This is the least invasive option and the right one for a single, specific
question. It does not scale to "why was this callback late", which is A's job.


D. SEGGER SystemView
--------------------

``CONFIG_TRACING_SYSVIEW=y`` (``subsys/tracing/sysview/``) feeds SystemView's
timeline and CPU-load GUI, which is a genuinely better analysis surface than
``parse_ctf.py``.

The transport is the catch: it writes through SEGGER RTT, whose live mode
wants a J-Link probe. On FVP/AVH there is no probe. RTT's control block is
just memory, so an offline dump over the gdb stub into a ``.SVDat`` is
conceivable, but it is a bespoke path.

**Verdict:** park this for the **S32Z270 hardware** lane, where a J-Link is
plausible. Not the FVP answer.


E. Percepio Tracealyzer
-----------------------

Zephyr carries a Percepio TraceRecorder module glue layer
(``zephyr/modules/percepio/CMakeLists.txt``, ``CONFIG_PERCEPIO_TRACERECORDER``),
and the upstream Zephyr manifest lists the ``percepio`` project at
``modules/debug/percepio``.

Two blockers for ASI:

1. ASI's ``actuation_module/west.yml`` is a **flat, explicit** manifest — it
   does not ``import`` Zephyr's manifest, so ``percepio`` is not fetched.
   Adding it is a two-line west entry.
2. TraceRecorder's port coverage skews Cortex-M/RISC-V; AArch64 Cortex-R
   support needs confirming before investing.

Tracealyzer is the best commercial timeline/statistics product in this space,
but it is licensed and the port question is open. Revisit only if CTF +
Trace Compass proves insufficient.


F. Model-side observation (FVP)
-------------------------------

Arm's FVP models support ``--plugin`` instrumentation (MTI-based trace) and
the GDB stub gives full non-intrusive memory/register access. That is a
*zero-perturbation* observation channel, which no on-target tracing route can
claim.

The trade-off is that the model sees instructions and addresses, not Zephyr
threads — reconstructing a task timeline means correlating the PC stream
against ``_kernel.current`` and the thread symbols. That is real work, and
only worth it to answer "is the on-target tracer itself distorting the
measurement". The model is not installed in this checkout
(``tools/fvp/`` is empty; CI downloads it), so the plugin surface has not been
verified here.


Findings from actually running it
=================================

Everything in this section was produced on the FVP with the model at
11.31.28, not read out of the source. ``./build.sh --trace`` plus
``scripts/capture-fvp-trace.sh`` is the path; the numbers came from a
``--dds-loopback-test`` capture that ran to "DDS loopback test passed".

**CONFIG_TRACING_ASYNC is fatal on this architecture. Use SYNC.**
This is the single most important result here, and it inverts the advice this
document originally gave.

``CONFIG_TRACING`` does ``select INSTRUMENT_THREAD_SWITCHING`` with no
condition, whereas ``CONFIG_SCHED_THREAD_USAGE`` guards the same select with
``if !USE_SWITCH``. arm64 is a ``USE_SWITCH`` architecture, so turning on
tracing -- and only tracing -- puts ``z_thread_mark_switched_in()`` into the
context-switch path at ``arch/arm64/core/switch.S:126``. In **async** mode
that hook reaches ``tracing_trigger_output()``, which calls
``k_timer_start()`` (``subsys/tracing/tracing_core.c:125``): a kernel timer
started from inside the context switch, touching timeout lists and the
scheduler lock while ``_current`` is half-switched and before the switch's
``ret``.

The image then dies ~160 ms into boot with a context restored from garbage:

.. code-block:: text

   ELR_ELn: 0x000000000002382c      <- __start (reset.S:122)
   ESR_ELn: 0x00000000620cd3fe      <- EC 0x18, trapped MSR; the ISS decodes
                                       to the `msr daifset, #0xf` at __reset
   x0..x18, lr: all 0x0             <- register state of a core out of reset
   >>> ZEPHYR FATAL ERROR 0: CPU exception on CPU 0

Switching to ``CONFIG_TRACING_SYNC=y`` fixes it outright: the same image then
runs a full capture with no fault. Bisected against a matrix of builds --
baseline (boots), statistics-only (boots), tracing+async at 4 CPUs (faults),
at 1 CPU (faults), without ``INIT_STACKS`` (faults), with the RAM backend
instead of UART (faults), tracing+sync (boots). SMP, ``INIT_STACKS``, the
socket hooks and the UART backend were each ruled out by build, not by
argument.

The cost of sync is real: the backend write happens in the traced context, so
the tracer perturbs the timing it is measuring more than async would. That is
the trade this platform offers -- async does not work at all.

**The counter runs during WFI, so there is no wall-clock span.**
An earlier revision of this document said absolute timestamps were
"uncalibrated, off by ~1330x". That framing was wrong, and the real behaviour
is both narrower and more useful to know.

Two captures of the same image, checked against the target's own console
clock:

.. list-table::
   :header-rows: 1
   :widths: 26 12 22 22 18

   * - capture
     - events
     - backsteps as wraps
     - excluding idle gaps
     - console
   * - controller (sparse)
     - 6403
     - **10.051 s**
     - 0.060 s
     - 10.204 s
   * - DDS loopback (dense)
     - 176865
     - 2654 s
     - 2.456 s
     - 12.214 s

The sparse capture reconstructs correctly -- two 32-bit rollovers plus a
1.461 s residue gives 10.051 s against a console reading of 10.204 s, inside
1.5 %. The dense one does not, and the reason is not wrap handling: **every**
backward step in it is an ``idle`` event followed by ``isr_enter``, all of
them rollover-shaped, with a near-constant wrap-adjusted delta of 500.679 ms.
Their count tracks the event count (618 of 176865, 4260 of 1007306 -- both
~0.4 %), not elapsed time.

Following that through: the FVP keeps CNTVCT advancing while the core sits in
WFI, at a rate unrelated to the tick clock that Zephyr's console timestamps
come from. It is not confined to the boundary either -- idle *slices*
themselves average ~338 ms, so a 12.214 s run accumulates ~2350 s of counter
time, essentially all of it inside idle.

Consequences, and they are workable:

* **Non-idle accounting is sound.** Those slices are bounded by real
  execution and agree across runs. The loopback capture gives 1986.8 ms of
  non-idle execution — about 16 % of the 12.214 s run, which is what a 1 Hz
  report loop over a network stack should look like.
* **The idle thread's figures, any total-elapsed, and any CPU-percent derived
  from them are meaningless here.** ``scripts/parse-zephyr-ctf.py`` therefore
  reports no wall-clock span, bases nothing on idle, and labels the idle rows.
* **Event counts, ordering and thread structure were never affected.**

For absolute latency work, prefer a short capture (under the 4.295 s rollover
period) with little idle in it, where the reconstruction is directly
checkable against the console.

**Socket tracing must stay off.** ``CONFIG_TRACING_NETWORKING`` defaults on,
and the CTF socket hooks dereference their arguments unchecked --
``sys_trace_socket_getsockname_exit()`` does
``net_addr_ntop(addr->sa_family, &net_sin(addr)->sin_addr, ...)`` and ``*addrlen``
without a NULL test or consulting ``ret``. It is disabled in
``tracing.conf``. Note this removes the DDS-bracketing use this document
advertises for the socket events.

**What a capture looks like.** The DDS-loopback workload, 1 CPU, sync + UART
backend, ~90 s of host time:

.. code-block:: text

   stream: 14350394 bytes -> 1007306 events, 0 skipped, 0 trailing
   mutex_lock_enter    135183     thread_switched_in/out  93426 each
   isr_enter/exit       44411     idle                    42117
   semaphore_give/take  36570

The controller lane itself never got that far: on the default network profile
the image stalls at ``Waiting for DHCP to get IP address...`` and never
reaches "Starting Controller Node", so no nano-ros tier threads or
``timer_start`` events appear. Reaching the control timer needs the TAP
profile (``scripts/setup-tap.sh``, which needs root).


Capturing the real control loop
===============================

The findings above came from the DDS-loopback workload. The controller lane
itself needs the TAP profile, and this is what it shows.

Getting there: ``sudo scripts/setup-tap.sh`` once, then
``scripts/sntp-server.py`` must be running on 192.168.10.1:12123 — the image
blocks on SNTP (``Setting time using SNTP...``) and gives up after ~11 s
without it, never reaching the controller. With it, the node comes up:

.. code-block:: text

   Time set using SNTP: Mon Aug 24 03:18:08 2026
   Starting Controller Node...
   Controller Node Started
   Actuation Safety Island is Live
   Control is skipped since input data is not ready.

Capture: 81398684 bytes, **6545980 events, 0 skipped, 0 trailing**, only 68 WFI
counter jumps (the system is busy rather than idle, so the WFI problem that
dominates an idle capture barely appears here).

**The executor wakes every 6 ms, not every 30 ms.**

.. code-block:: text

   main dispatches:     59635
   inter-dispatch ms:   min 0.164   p50 6.0000   p90 6.0007   p99 7.0   max 1000.8
   gaps in 25-35 ms:    0
   main slice ms:       p50 0.669   p99 1.031   max 62.102

The bringup declares ``ctrl_period=0.03``, but there is no 30 ms cadence
anywhere in the thread timeline — not one inter-dispatch gap falls in a
25–35 ms window. The executor thread wakes on a fixed 6.000 ms period, roughly
166 Hz, and each wake does about 0.67 ms of work. That is five wakes per
control period.

Read this carefully, because the trace does **not** say the control callback
runs at 6 ms. Callbacks execute inside a wake, as ordinary function calls, so
thread-level tracing cannot see their boundaries. What the trace establishes is
the *executor's* cadence and cost; relating that to the control period needs
either a kernel timer (see below) or application-level instrumentation.

**The control period is not driven by a Zephyr timer.** ``CONFIG_TRACING_TIMER``
is enabled and the capture contains **zero** ``timer_start`` events. nano-ros
paces its executor itself rather than through ``k_timer``, so the timer event
family — which this document previously recommended as the way to separate a
mis-armed period from a mis-delivered one — yields nothing on this lane. That
technique needs a kernel timer to observe, and there isn't one.

**The tier model IS active — but it runs on ``main``, not a spawned thread.**
An earlier revision of this document read the thread list and concluded the
phase-4 ``[tiers.control]`` model was not in effect on this lane. That was
wrong, and the reasoning is worth recording because the evidence looks
identical either way.

Every thread the image creates:

.. code-block:: text

   asi_thread_stats   stack 16384    (this repo's statistics reporter)
   7 x "unknown"      stack 32768    (nano-ros generic transport pool)

No thread uses ``NROS_ZEPHYR_TIER_STACK_SIZE`` (16384), which looks like "no
tiers". It is not. From nano-ros ``entry_tiers.rs``: *the caller thread opens
the boot* ``Executor``\ *, runs the boot tier's setup, then CHAIN-spawns the
remaining tiers*. ASI declares exactly one tier, so ``control`` **is** the boot
tier and runs on the caller — ``main``. There is nothing left to spawn.

The generated entry confirms it:

.. code-block:: c

   static const ::nros::board::NativeTierSpec __nros_tiers[1] = {
       { "control", __nros_tier_0_groups, 1u, 9LL, 0u, 5000ull, ... "real_time", ...},
   };
   int main(void) { return ZephyrBoard::run_tiers(..., __nros_tiers, 1u); }

and ``main`` adopts the tier's priority through
``nros_zephyr_set_current_priority()`` →
``k_thread_priority_set(k_current_get(), ...)``.

That also explains the 6 ms cadence measured above: ``spin_period_us = 5000``
gives ``period_ms = 5``, and ~1 ms of work per spin lands the observed
6.000 ms. Nothing is mis-scheduled.

**Why the trace cannot show the priority.** Zephyr 3.7's
``z_impl_k_thread_priority_set()`` contains no tracing hook, even though
``subsys/tracing/ctf/ctf_top.c`` implements ``sys_trace_k_thread_priority_set``
and the TSDL declares the event. A capture therefore contains **zero**
``thread_priority_set`` events no matter what the application does, and the
absence proves nothing. Filed as issue 4 in
``docs/design/upstream-zephyr-issues.md``. Reading that absence as evidence is
what produced the wrong conclusion above.

**A real defect this did surface.** The bringup declared
``[tiers.control.zephyr] priority = 5``. nano-ros RFC-0079 allocates Zephyr's
bands with the DDS transport at 7 and the tier pool at [8, 14], so 5 sat
*above the transport* — the control tier could preempt the transport it
depends on to receive trajectories and publish commands. Upstream closed the
same violation in its own bringups by moving 5 to 9; this consumer bringup had
not followed. Now 9.

Measured either side of that change, on an idle system, the cadence is
**identical** — p50 6.0000 ms, p99 7.0000 ms, slice p50 0.6690 ms both ways.
That is the expected result and not a null one: with no planner attached the
transport is idle, so the two never contend and the priority relationship is
never exercised. The fix is correct by allocation; demonstrating its effect
needs the loaded measurement.

**Generic pool threads are unnamed.** ``nros_zephyr_tier_task_create()`` calls
``k_thread_name_set()``, but the generic pool path does not, so the seven
transport threads appear as ``unknown`` and are separable only by thread id and
stack base.

The cause is narrower than "nano-ros does not name threads". The ABI has
carried a ``name`` in ``nros_platform_task_attr_t`` all along, every caller
fills it, and the FreeRTOS port hands it to ``xTaskCreate`` -- which is why the
same application traces as ``nros_app`` and ``zpico_read`` there. Only the
Zephyr port's generic path read ``priority`` out of the attr and dropped
``name``. Fixed in nano-ros PR #159 (``fix/zephyr-port-drops-task-name``);
until that lands and the pin moves, expect ``unknown`` rows.

**Longest slice.** ``main`` shows a 62.1 ms worst contiguous slice against a
0.67 ms median. Worth attention if the 30 ms period matters, though note the
capture ran without a planner attached, so this is not a loaded-system figure.

RESOLVED once markers landed: that slice is **not** the control callback. The
callback's own duration is 0.721 ms p50, 1.456 ms max on the same lane, so
whatever occupies the 62.1 ms is elsewhere in the executor thread.

.. note::

   A decoder bug found on 2026-08-29 mis-paired cycle durations — the walk
   closed a cycle at the first *phase* marker rather than at EXIT. It does
   **not** invalidate the two figures above, and the reason is worth recording
   rather than asserting. Mis-pairing only affects cycles that emit a phase
   marker, i.e. cycles that reached the controllers. This lane logged
   "Control is skipped since input data is not ready" throughout: every cycle
   was a safe stop, which returns from ``createInputData`` before any phase
   marker is emitted, so ENTER paired with EXIT correctly here. On the loaded
   lane, where commanded cycles do exist, the same bug understated the maximum
   by two orders of magnitude (20.8 ms reported against 4545.7 ms actual).

This is a good illustration of why thread-level tracing alone could not answer
the question — a callback runs inside a wake as an ordinary function call, and
the timeline cannot see its boundaries. See the loaded section below.


What the loaded control loop costs
==================================

Everything above was captured with no planner attached. ``run-tap-demo.sh
--drive`` runs an autonomous mission end to end, which makes the controller do
real work, and that changes the picture completely. Application markers
(mechanism C, extended with ``app_marker``) split the callback into phases;
the numbers below are p50 over cycles that reached the controllers, decoded
from a SETTLED capture after teardown.

**The control loop does not meet its 30 ms period, and the reason is the MPC
solve.** Not scheduling, not tier priority, not the transport, not the port —
each of those was a hypothesis and each was killed by a measurement rather than
an argument::

    phase                 p50 ms
    in:process_data        0.011     flag checks
    in:copy_inputs         0.169     the 8.8 KiB trajectory deep copy
    in:is_ready           21.85      setTrajectory -> setReferenceTrajectory
    mpc_lateral          227.5       the QP
    pid_longitudinal       2.6
    publish                1.9

Note ``in:copy_inputs``. Phase 4 suspected trajectory deserialization, and so
did this document's author; it costs 0.169 ms. The cost is in the solve.

.. note::

   **"Not preemption" was wrong, and is corrected here.** That claim came from
   period tracking duration, which is inference, not measurement. Phase 9
   subtracted the intervals in which the owning thread was off CPU:

   .. code-block:: text

      timer@30000us   wall p50 1.401   wall max 393.510
                      exec p50 1.274   exec max 226.969   preempted 19399.585

      preempted by: unknown (0x00281cc0) 8653.9 ms, rx_q[0] 7997.1 ms,
                    sysworkq 2090.5 ms

   ``exec max`` 226.969 ms lands on the 227 ms figure above, so the solve does
   dominate CPU time and that conclusion stands. But 166 ms of the 393 ms worst
   case is time OFF CPU, 19.4 s across the run. Both are true: the callback
   runs long AND it is preempted, mostly by the DDS receive queue and an
   unnamed nano-ros pool thread.

   This distinction matters for the contract, not just for accuracy: a
   ``budget_us`` is execution time and a ``deadline_us`` is response time, and
   before phase 9 every figure in this document was the latter.

A duplicated call, and what it was worth
----------------------------------------

``MpcLateralController::isReady()`` and ``::run()`` each called
``setTrajectory()`` with identical arguments, one immediately after the other,
because the node calls ``isReady(input)`` then ``run(input)`` on the same
object. The most expensive operation in the cycle ran twice per commanded
cycle, and the trajectory was pushed into the shape-change detection buffer
twice.

Removed from ``run()``, not from ``isReady()`` — the latter's own
``m_reference_trajectory.empty()`` check is *satisfied by* the call, so
removing it there returns false forever and ``run()`` is never reached.
Measured on the same workload: ``mpc_lateral`` 298.1 -> 227.5 ms,
``in:is_ready`` 33.95 -> 21.85 ms, cycle ~340 -> ~254 ms, about 25 %.

Reading the rest of the hot path for the same pattern found nothing more.
``PidLongitudinalController::isReady()`` is ``return true;``.
``MPC::setReferenceTrajectory`` is a linear pipeline with no internal
duplication, and two of its blocks never execute here at all
(``enable_path_smoothing`` and ``extend_trajectory_for_end_yaw_control`` both
default false), so the moving-average filter — a recurring cost suspect — is
dead code at runtime on this lane.

The cost is the QP, and it scales with the horizon
--------------------------------------------------

With the default ``vehicle_model_type = "kinematics"`` (dim_x 3, dim_u 1,
dim_y 2) and ``mpc_prediction_horizon = 50``, ``generateMPCMatrix`` builds
``Cex`` 100x150, ``Qex`` 100x100, ``Bex`` 150x50. The cost function
``H = B'C'QCB + R`` evaluates as ``Cex*Bex`` (750k MAC), ``CB'*Qex`` (500k),
``*CB`` (250k) — about **1.5M double MACs per cycle**, every matrix a heap
allocated Eigen ``MatrixXd`` plus temporaries. That allocation pressure is why
``CONFIG_HEAP_MEM_POOL_SIZE`` had to go from 192 KiB to 4 MiB.

Sweeping the horizon confirms it::

    N     lookahead   mpc_lateral p50   commanded cycle   period p90   period max
    50      5.0 s        226.937 ms         261.1 ms        270 ms       4560 ms
    25      2.5 s         73.046 ms          94.5 ms        113 ms       4408 ms
    15      1.5 s         43.886 ms          64.7 ms         81 ms        176 ms

    fit: mpc_lateral = 0.0821 * N^2 + 21.75 ms   (8.4 % residual at N=15)
    implied exponent 50 -> 25: 1.64

Superlinear, as the matrix shapes predict. A data-movement bottleneck would be
linear; an unconverged solve would not track N^2 at all, and there is no
iteration to be unconverged in — ``qp_solver_type`` defaults to
``unconstraint_fast``, the direct solve. The tail collapses too: the
multi-second worst cases present at N=50 and N=25 are simply absent at N=15,
whose worst solve is 97 ms.

Two cross-checks worth keeping. The N=50 point reproduces at 226.937 ms
against 227.5 ms measured on a different mission, so ``mpc_lateral`` is
mission-insensitive and horizon-driven. ``in:is_ready`` is **not**: it reads
30.6 / 16.9 / 17.1 ms across the sweep and 21.85 ms earlier, varying as much at
constant N as across the whole sweep. Do not read a horizon dependence into it;
the trajectory pipeline does not use the horizon.

Why tuning cannot close the gap here
------------------------------------

The fit has a horizon-independent floor of 21.75 ms inside ``mpc_lateral``
alone. Across the commanded cycle::

    inputs ~17.0 + mpc floor 21.75 + pid ~2.6 + publish ~1.05  =  ~42.4 ms

So **no horizon meets 30 ms on the FVP** — not N=15, not N=1. The horizon is a
large lever (5.2x from 50 to 15) and it is not enough.

.. warning::

   **None of the millisecond figures on this page are silicon numbers.**
   ``FVP_BaseR_AEMv8R`` is an Arm Fast Model: programmer's view,
   instruction-accurate, **not cycle-accurate**. Its wall-clock is a property
   of the simulator, not of a Cortex-R52. 1.5M double MACs is not a 227 ms
   workload on an R52 with an FPU, and a ~100x gap is consistent with the
   model and with nothing else.

   The floor above is therefore an artifact too, which is precisely why no
   further FVP capture can decide whether ``ctrl_period = 0.03`` is
   achievable. That question unblocks on a run against S32Z hardware or a
   cycle-accurate model — or, without hardware, on an instruction count for
   the solve span (mechanism F) divided by the R52 issue rate.

   What the FVP *does* establish soundly is everything relative: which phase
   dominates, that a call was duplicated, and how cost scales with the
   horizon. Ratios survive the model; absolute times do not.

The parameters behind all of this
---------------------------------

``mpc_lateral_controller.cpp`` makes 69 ``declare_parameter`` calls. The launch
seeds two (``control_output``, ``ctrl_period``) plus
``mpc_prediction_horizon``, added at its compiled default of 50 so that the
largest cost lever is owned by the deployment rather than a C++ literal.
Everything else runs on compiled defaults with no runtime path, which is worth
knowing before anyone plans a retune. Changing the horizon is a controls
decision: lookahead is N * ``mpc_prediction_dt``, so N=15 trades 5.0 s of
prediction for 1.5 s.


Caveats read out of the source
==============================

These are properties of Zephyr v3.7.0 as pinned, not hypotheticals. Each one
was confirmed in the tree.

**CTF timestamps are 32-bit nanoseconds and wrap every ~4.29 s.**
``subsys/tracing/ctf/ctf_top.h:55``:

.. code-block:: c

   const uint32_t tstamp = k_cyc_to_ns_floor64(k_cycle_get_32());

A 64-bit nanosecond value truncated to ``uint32_t``. Any capture longer than
about four seconds needs wrap reconstruction in post-processing (monotonic
unwrapping on the parsed stream). Plan capture windows in seconds, not
minutes, or budget for the unwrap step.

**The CTF event header carries no CPU id.** ``struct event_header`` in the
TSDL metadata is ``{ uint32_t timestamp; uint8_t id; }`` and nothing else.
Under SMP, events from different cores interleave with no way to separate
them. ASI's ``CONFIG_SMP=n`` makes this a non-issue **today** — but it means
the CTF route quietly loses fidelity if the lane goes multi-core. If SMP is
ever needed alongside tracing, pin the traced tiers with the ``core`` knob
(``nros_zephyr_tier_task_create()`` supports it) and treat the trace as
per-tier rather than system-wide.

**The tracing buffer is protected by ``irq_lock()`` only.**
``subsys/tracing/include/tracing_core.h:17`` defines ``TRACING_LOCK()`` as a
bare ``irq_lock()``. That is not an SMP-safe critical section: two cores can
enter concurrently and corrupt the buffer. Same conclusion as above, but this
one is silent corruption rather than ambiguous output — do not enable CTF
tracing on an SMP image without fixing the lock first.

**The RAM backend is not a ring.** ``tracing_backend_ram.c`` sets
``buffer_full = true`` on overflow and drops everything afterwards. You get
the first N bytes of a run, never the last N. For "what happened just before
the anomaly" you need the UART backend, or a locally patched ring.

**Tracing perturbs what it measures.** Use ``CONFIG_TRACING_ASYNC=y`` so the
hot path only fills the buffer and a dedicated thread drains it. Keep an eye
on ``tracing_packet_drop_num`` — the core counts drops
(``tracing_core.c:161``) rather than blocking, so a saturated link silently
thins the trace. Enable only the event categories you need; the socket family
is the loudest by far on this workload.


Recommendation
==============

A two-layer setup, in this order:

**Layer 1 — statistics, always on (cheap).** Turn on
``CONFIG_THREAD_RUNTIME_STATS`` + ``CONFIG_SCHED_THREAD_USAGE_ANALYSIS`` +
``CONFIG_THREAD_ANALYZER`` with ``THREAD_ANALYZER_AUTO`` for every FVP CI run.
Cost is a periodic printk. Benefit is that every CI log artifact gains
per-thread CPU share, dispatch counts, ``longest`` slice, and stack high-water
marks — turning the existing ``require_marker`` phases into regression
detectors for scheduling behaviour, not just liveness. This is the highest
value-per-effort item on the list.

**Layer 2 — timeline, on demand (a build profile).** ``./build.sh --trace``
layers ``tracing.conf`` plus the ``zephyr,tracing-uart = &uart1`` overlay and
appends the ``bp.pl011_uart1.out_file`` flag; ``scripts/capture-fvp-trace.sh``
drives build, run and decode. Both exist and are exercised. Decode with
``scripts/parse-zephyr-ctf.py`` -- upstream's ``parse_ctf.py`` needs the
babeltrace2 ``bt2`` bindings, which this host does not have, whereas the local
script reads the TSDL directly and needs nothing.

Two mechanical points that cost a session each: the FVP applies the **last**
repeated ``-C`` option, so the uart1 redirect must be appended after
``board.cmake``'s ``out_file=-`` (which is what ``ARMFVP_EXTRA_FLAGS`` does);
and ``west build --target run`` re-runs Cargo first, so a short timeout is
consumed by the rebuild before the model ever boots -- drive the model
directly for timed captures.

Skip SystemView and Tracealyzer for now: SystemView belongs to the S32Z
hardware lane, Tracealyzer is licensed and its AArch64-R port is unconfirmed.
Keep the FVP plugin route in reserve as the tie-breaker if the on-target
tracer's own overhead becomes the suspect.


What this is for
================

The original motivation for this study was **nano-ros issue 0746** ("30 ms
timer runs at ~50 Hz under real traffic, exact standalone"). That issue was
**closed wontfix on 2026-08-21**, before this tooling could be pointed at it,
and the resolution is worth recording because it shapes what the tooling is
actually good for.

There was no scheduling defect. The ~50 Hz was ``ros2 topic hz`` aggregating
**three stale duplicate island processes** publishing on the same domain;
min≈0 bursts with max≈period is the multi-publisher signature. Instrumented
upstream accounting showed per-spin credit matching the tick clock to the
microsecond, and single-process measurement under the full planner graph gave
31.669 Hz on the wire (min 31 / max 32 ms, σ 0.06 ms). The upstream rule that
came out of it: **prove the publisher count first**
(``pgrep -a actuation_posix_entry`` / ``ros2 topic info -v``).

That is a useful lesson for this document rather than a defeat of it. A whole
round of rate analysis was spent on an artifact that no amount of on-target
tracing would have explained, because the fault was on the *host* side of the
measurement. Reach for the target-side timeline once the measurement itself is
trusted — not before.

Where the two layers still earn their keep:

* **Layer 1 in CI.** ``longest`` (worst contiguous slice) and ``num_windows``
  (dispatch count) per thread, printed into the existing FVP log artifacts,
  turn the ``require_marker`` phases into regression detectors for scheduling
  behaviour rather than liveness alone. Neither number can be faked by a
  host-side measurement artifact.
* **Layer 2 for displacement questions.** When something *is* late on target,
  the ``thread_ready`` → ``thread_switched_in`` gap separates "released late"
  from "released on time and preempted", and the ``isr_enter``/``isr_exit``
  lanes show what displaced it. ``timer_start`` carries the requested
  ``duration`` and ``period`` in ticks alongside the arm time, so a wrong
  requested period is distinguishable from a wrong delivered interval without
  inferring either.

Non-idle execution times, dispatch counts and orderings are all usable today.
What the model does not give is a wall-clock span or a CPU percentage — see
the WFI counter behaviour in `Findings from actually running it`_.
