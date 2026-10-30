.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

=========================
How Zephyr tracing works
=========================

Reference for the subsystem the other tracing documents assume:
:doc:`trace_extraction` is the procedure, :doc:`trace_on_hardware` is the
handoff to real silicon, :doc:`trace_findings` is what our captures showed.

Written because almost every failure mode here is silent and produces
plausible output. Knowing the shape of the subsystem is what lets you check
the mechanism instead of the result.

.. note::

   File and line references are the Zephyr **3.7** tree this repo pins.
   Both drift across versions and one behaviour genuinely differs on 4.4;
   it is called out where it matters. Cite the tree alongside the line.


Three choices, and they are not independent
===========================================

Kconfig presents three orthogonal selections:

.. list-table::
   :header-rows: 1
   :widths: 12 30 40 18

   * - Layer
     - Decides
     - Options
     - Default
   * - **Format**
     - what the bytes mean
     - ``TRACING_NONE``, ``PERCEPIO_TRACERECORDER``, ``SEGGER_SYSTEMVIEW``,
       ``TRACING_CTF``, ``TRACING_TEST``
     - none
   * - **Method**
     - how emit reaches the backend
     - ``TRACING_SYNC``, ``TRACING_ASYNC``
     - **async** (``Kconfig:81``)
   * - **Backend**
     - where the bytes go
     - UART, USB, POSIX, RAM, ADSP_MEMORY_WINDOW; SEMIHOST on 4.4+
     - **UART** (``Kconfig:134``)

They are orthogonal in the configuration and **not** orthogonal in
consequence. Method and backend in particular are one decision, for the
reason in `The coupling`_ below. Treating them as two is how this repo came
to hold a configuration that cannot run on hardware.

Formats are mutually exclusive, which has one non-obvious consequence: RTT
appears in this subsystem only under ``SEGGER_SYSTEMVIEW``, a *format*. There
is no RTT *backend*, so RTT and CTF cannot be combined. On a board whose only
console is RTT-over-SWD that is worth knowing before planning around it.


The emit path
=============

.. code-block:: text

   k_thread_switched_in()                    kernel call site
    | sys_port_trace_k_thread_switched_in()  tracing_ctf.h:63
    | sys_trace_k_thread_switched_in()       gated by CONFIG_TRACING_THREAD
    | ctf_top_thread_switched_in()           ctf_top.h:170
    |   CTF_EVENT(...)                       ctf_top.h:52
    |     tstamp = k_cyc_to_ns_floor64(k_cycle_get_32())    <- uint32_t
    |     CTF_GATHER_FIELDS(...)             packs into a stack buffer
    |     tracing_format_raw_data(pkt, len)  ctf_top.h:49
    |
    +-- SYNC   TRACING_LOCK(); tracing_buffer_handle(); TRACING_UNLOCK()
    |          no drop path on this route
    |
    +-- ASYNC  ring-buffer put
               |  ok   -> wake the tracing thread
               |  fail -> tracing_packet_drop_handle(), event lost whole
               +-> backend->output(data, len)

**Version difference.** On 3.7 ``CTF_EVENT`` gathers fields without holding a
lock; the only ``irq_lock`` is inside ``TRACING_LOCK``. On 4.4 the macro
itself opens with ``int key = irq_lock();`` and closes with ``irq_unlock``,
so field packing is covered too. The conclusion below is unchanged either
way, because the expensive part is the backend write and that is locked on
both.


The coupling
============

``TRACING_LOCK()`` is ``irq_lock()`` -- ``tracing_core.h:17``, literally::

    #define TRACING_LOCK()   { int key; key = irq_lock()

It wraps the entire backend output call. So **sync has no cost of its own; it
has the backend's write cost, paid with interrupts disabled.**

.. list-table::
   :header-rows: 1
   :widths: 18 82

   * - Backend
     - Cost under SYNC, interrupts off
   * - RAM
     - bounded ``memcpy``. Microseconds. Fine.
   * - UART
     - ``tracing_backend_uart.c:73`` is a byte-at-a-time ``uart_poll_out``
       loop, and that call blocks until the transmitter is ready. At 115200
       that is 86.8 us per byte, so a 14-byte event holds interrupts off for
       **1.215 ms**.
   * - SEMIHOST
     - ``semihost_write`` is ``bkpt 0xab``: the core halts until the debug
       probe services it. Once per event. It also makes the image
       undeployable standalone, since ``bkpt 0xab`` with no probe attached
       faults rather than degrading.

Async avoids the lock cost by moving the write to the tracing thread, and
pays for it with the drop path instead. There is no third option.


What sets the data rate
=======================

Roughly twenty Kconfig switches, one per event family: ``THREAD``, ``WORK``,
``ISR``, ``SEMAPHORE``, ``MUTEX``, ``CONDVAR``, ``QUEUE``, ``FIFO``,
``LIFO``, ``STACK``, ``MESSAGE_QUEUE``, ``MAILBOX``, ``PIPE``, ``HEAP``,
``MEMORY_SLAB``, ``TIMER``, ``EVENT``, ``POLLING``, ``PM``.

This is the only real throttle, and everything downstream follows from it.
With all of them on, our TAP capture produced:

.. code-block:: text

   6545980 events over 84.063 s   =  77870 events/s
   91933547 bytes                 =     14.0 bytes/event
                                  =   1.09 MB/s sustained
                                  =  ~10.9 Mbaud to keep up live

Cutting the set is not only a bandwidth decision. Against a fixed-size
backend it sets the observable window, and against sync it decides whether
the interrupts-off cost is survivable. Keep what answers the question --
``app_marker`` plus thread switches carries release cadence and preemption
-- and drop the rest deliberately.


The timestamp wraps every 4.295 s
=================================

.. code-block:: c

   const uint32_t tstamp = k_cyc_to_ns_floor64(k_cycle_get_32());

Nanoseconds truncated to 32 bits, so the period is **4.295 s on every target
regardless of clock rate**. Do not reason from the counter width: at 160 MHz
``k_cycle_get_32()`` wraps at 26.8 s, but the nanosecond truncation happens
first. Gated by ``TRACING_CTF_TIMESTAMP``, which is ``default y`` and depends
on ``TRACING_CTF``, so it cannot be quietly off while CTF is on.

Unwrapping is therefore ambiguous. An observed gap of ``g`` could equally be
``g``, ``g + 4.295 s`` or ``g + 8.59 s``, and nothing in the stream
distinguishes them; ``scripts/parse-zephyr-ctf.py`` always assumes the
smallest and reports when it had to. A quiet stretch longer than the wrap
period loses whole epochs and every later timestamp is wrong by a multiple.

The repair is a periodic ``app_marker`` carrying a monotonic sequence counter
in its ``arg``, which makes elapsed time between heartbeats known
independently of the timestamp. See :doc:`trace_on_hardware`.


The stream carries no schema
============================

A Zephyr CTF capture is bare event records. The TSDL that names them is a
file in the tree, ``subsys/tracing/ctf/tsdl/metadata``, paired with the
stream by convention and checked by nothing.

Event ids are positions in that file. Decoding a stream against a different
tree's TSDL therefore renames events and misreads fields **silently** rather
than failing. Decode with the metadata from the tree that built the image
(``parse-zephyr-ctf.py -m``, which defaults to this repo's pinned copy).

Our copy is also patched, so it is not interchangeable with a stock one in
either direction.


What this repo runs, and what it adds
=====================================

.. code-block:: text

   CONFIG_TRACING_CTF=y
   CONFIG_TRACING_CTF_TIMESTAMP=y
   CONFIG_TRACING_SYNC=y            <- overrides the async default
   CONFIG_TRACING_BACKEND_UART=y
   CONFIG_TRACING_BUFFER_SIZE=16384
   CONFIG_TRACING_PACKET_MAX_SIZE=32
   ... every event family enabled

Sync is why our captures have no holes. UART is survivable only because the
FVP models it and ``uart_poll_out`` returns in negligible model time; on
silicon this pair is the 1.215 ms case above. **This configuration is not a
hardware template.**

Three out-of-tree patches under ``patches/zephyr/``:

``0001-ctf-trace-k_thread_priority_set.patch``
   Adds a trace point upstream lacks, so a priority change is visible in the
   timeline rather than inferred from later scheduling.

``0002-ctf-app-marker-event.patch``
   Adds ``app_marker`` (id 0x70): the ``sys_trace_app_marker()`` function,
   the ``ctf_top_app_marker()`` inline, **and the TSDL entry**. Zephyr 3.7
   has no user-event facility; upstream's ``named_event`` came later. All
   three parts are needed -- without the TSDL half a marker is emitted and
   cannot be decoded.

``0003-tracing-allow-an-out-of-tree-backend.patch``
   16 Kconfig lines. Upstream hardcodes the backend name in
   ``tracing_core.c`` and offers no way to select your own, even though
   ``TRACING_BACKEND_DEFINE()`` exists. This makes it selectable, which is
   what any custom backend (an RTT one, for instance) would need.


Traps, ordered by how easily you hit them
=========================================

1. **The defaults.** Async + UART, changing nothing, drops events silently.
   Flipping the one knob a reader is most likely to flip, because sync sounds
   like the safer name, gives 1.215 ms interrupts-off instead. The
   safer-sounding name is the worse one and neither default is usable.

2. **Async loses events invisibly.** Whole events are dropped, so framing
   stays intact and a decoder sees nothing wrong -- a capture that lost a
   third of its events looks exactly like a clean one.
   ``tracing_packet_drop_num`` (``tracing_core.c:46``) counts them into a
   ``static atomic_t`` with no accessor, no shell command and no reader
   anywhere in the tree. Async also skips events emitted by the tracing
   thread itself, so the tracer's cost never appears in its own trace.

3. **The 4.295 s wrap**, eating epochs across any quiet stretch.

4. **Schema pairing**, silently renaming events.

5. **The RAM backend is one-shot, not a ring.** It fills once, latches
   ``buffer_full`` and records nothing further until re-init, truncating the
   tail. That is the better failure mode -- a prefix is analysable where a
   hole-riddled stream is not -- and unlike the drop counter it is detectable
   from the artifact via ``pos``. The default size is 4096 bytes, about 290
   events, so the size is not optional. Dump ``ram_tracing[0 .. pos]``: init
   zero-fills the array and a full-array dump appends zeros a decoder reads
   as trailing garbage.


The discipline that follows
===========================

Every trap above produces a clean-looking artifact. A well-formed stream is
not evidence of a complete one, a plausible occupancy is not evidence of a
valid time base, and a decode that names events is not evidence the right
TSDL was used.

So check the mechanism rather than the result. Concretely, for each capture:
read the ``[wrap]`` verdict before quoting an absolute time; read
``segments_dropped_counter_jump`` and treat non-zero on hardware as
corruption rather than routine; read ``pos`` against the buffer size on the
RAM backend; and record in ``trace_meta.json``, at capture time, which tree
built the image and which knobs were set.

The one measurement that would have saved the most rework here was not a
measurement at all: it was reading down to what the backend actually does,
rather than to the layer above it.
