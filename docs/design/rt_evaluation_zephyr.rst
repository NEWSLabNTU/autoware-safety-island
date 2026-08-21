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

**Why the thread names are useful.** nano-ros creates real, named Zephyr
threads for its RT tiers — ``nros_zephyr_tier_task_create()`` in
``modules/nros/zephyr/nros_platform_zephyr_shims.c:445`` calls
``k_thread_create()`` at the tier's raw priority and then
``k_thread_name_set(tid, name)``. So ``[tiers.control]`` shows up in the trace
under its authored name, not as an anonymous TID.

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

**Absolute timestamps do not calibrate on this board.**
A capture whose console clock showed 12.214 s of run time reconstructs as
~18300 s of trace span -- a factor of ~1330. This is *not* 32-bit wrap
handling: summing only the forward deltas and ignoring every backward step
still yields ~16200 s. Framing is confirmed sound (clean 5-byte
``idle``/``isr_enter``/``isr_exit`` records, 1,007,306 events decoded with
**0 bytes skipped and 0 trailing**), and ``CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC``
is 100 MHz as expected, so the discrepancy is in how the CTF timestamp relates
to the clock the console uses -- unresolved.

Consequence: **use this trace for event counts, ordering, and thread
structure; do not quote latencies from it** until the scale is understood.
``scripts/parse-zephyr-ctf.py`` prints a warning to that effect. Every
backward step in the capture was an ``idle`` event followed by ``isr_enter``,
which is where the investigation should resume.

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


Applying this to nano-ros 0746
==============================

Issue 0746 — "30 ms timer runs at ~50 Hz under real traffic, exact
standalone" — is the natural first target, and it is precisely the shape of
question a timeline answers and a printk cannot.

The competing explanations are distinguishable in a CTF trace:

* **Tick quantisation / re-arm short.** The lane runs a 1 ms tick against a
  30 ms period -- 30 ticks -- so quantisation alone is a weak explanation.
  (An earlier revision of this document claimed a 10 ms tick and built a
  "50 Hz is exactly two ticks" argument on it. That was wrong: the tick comes
  from the nano-ros bundle at 1000 Hz, not the board defconfig's 100 Hz.)
  The ``timer_start`` events still settle it directly, because each carries
  the REQUESTED ``duration`` and ``period`` in ticks alongside the arm time.

* **Executor over-crediting.** If ``timer_start`` stays at 30 ms but the
  control tier is dispatched twice per period, the executor is crediting
  elapsed-but-unserviced ticks — the ``thread_ready`` → ``thread_switched_in``
  pairs for the tier thread show the dispatch count against the timer arms.
* **Preemption by the network path.** ``socket_recvfrom_*`` and ``isr_enter``
  events bracketing the control tier's slice show whether "under real
  traffic" means the tier is being displaced rather than mis-scheduled.

The ``longest`` / ``num_windows`` fields from Layer 1 give a cheap first
discriminator before any trace is captured: if ``num_windows`` for the control
tier is ~2× the expected 33 Hz dispatch count over the run, that is the
over-crediting arm without needing a timeline at all.

Worth settling the tick-rate question first, independently: the nano-ros board
bundle asks for a 1 ms tick and the ASI lane silently does not apply it. That
divergence should be a deliberate choice, not an artifact of which conf
fragments ``build.sh`` happens to pass.
