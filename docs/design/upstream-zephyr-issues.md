<!--
Copyright (c) 2026, Arm Limited.
SPDX-License-Identifier: Apache-2.0
-->

# Upstream Zephyr issue drafts

Three defects found while bringing up CTF tracing and thread statistics on the
FVP lane (`docs/design/rt_evaluation_zephyr.rst`). All three are in Zephyr
itself, none is ASI-specific, and each reproduces on any board with the same
properties.

**FILED 2026-08-27** as zephyrproject-rtos/zephyr
[#117634](https://github.com/zephyrproject-rtos/zephyr/issues/117634) (async tracing),
[#117635](https://github.com/zephyrproject-rtos/zephyr/issues/117635) (socket hooks),
[#117636](https://github.com/zephyrproject-rtos/zephyr/issues/117636) (analyzer stack),
[#117637](https://github.com/zephyrproject-rtos/zephyr/issues/117637) (priority_set event).

**All were still present in mainline** (checked 2026-08-24 against
`zephyrproject-rtos/zephyr@main`), and a search of the issue tracker found no
existing report for any of them. `scripts/file-upstream-issues.sh` generates
the issue bodies from this file and files them with `gh`.

Environment for both: Zephyr **v3.7.0** (`36940db938a`), board
`fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp`, Zephyr SDK 0.16.3, Arm FVP
`FVP_BaseR_AEMv8R` 11.31.28.

---

## Issue 1 — `CONFIG_TRACING_ASYNC` starts a kernel timer from inside the context switch on `USE_SWITCH` architectures

**Severity:** the image does not boot. Affects every `USE_SWITCH` arch
(arm64, riscv, xtensa, …) that enables tracing with the default tracing
method.

### What happens

Enabling tracing on arm64 with the default `CONFIG_TRACING_ASYNC=y` faults
about 160 ms into boot, with a context restored from garbage:

```
*** Booting Zephyr OS build v3.7.0 ***
<err> os: ELR_ELn: 0x000000000002382c      <- __start (arch/arm64/core/reset.S:122)
<err> os: ESR_ELn: 0x00000000620cd3fe      <- EC 0x18 (trapped MSR); the ISS
                                              decodes to the `msr daifset, #0xf`
                                              that IS the first instruction of __reset
<err> os: x0..x18: all 0x0, lr: 0x0        <- register state of a core out of reset
<err> os: >>> ZEPHYR FATAL ERROR 0: CPU exception on CPU 0
<err> os: Halting system
```

### Why

`CONFIG_TRACING` selects the switch instrumentation with **no condition**:

```kconfig
# subsys/tracing/Kconfig:13
config TRACING
	select INSTRUMENT_THREAD_SWITCHING
```

while the kernel's own users of the same symbol guard it:

```kconfig
# kernel/Kconfig:525 and :533
	select INSTRUMENT_THREAD_SWITCHING if !USE_SWITCH
```

So on a `USE_SWITCH` architecture, tracing — and only tracing — puts
`z_thread_mark_switched_in()` into the switch path:

```asm
# arch/arm64/core/switch.S:126
#ifdef CONFIG_INSTRUMENT_THREAD_SWITCHING
	str	lr, [sp, #-16]!
	bl	z_thread_mark_switched_in
	ldr	lr, [sp], #16
#endif
	/* Return to arch_switch() or _isr_wrapper() */
	ret
```

In **async** mode that hook reaches
`tracing_format_raw_data()` → `tracing_trigger_output()`, which calls:

```c
/* subsys/tracing/tracing_core.c:125 */
void tracing_trigger_output(bool before_put_is_empty)
{
	if (before_put_is_empty) {
		k_timer_start(&tracing_thread_timer, ...);
	}
}
```

`k_timer_start()` manipulates timeout lists and takes the scheduler lock —
from inside the context switch, on the incoming thread, with `_current`
half-switched and before the switch's `ret`.

### Workaround

`CONFIG_TRACING_SYNC=y`. The same image then runs indefinitely and produces a
valid CTF stream. Sync has a real cost (the backend write happens in the
traced context, so tracing perturbs the timing it measures), but async does
not work at all here.

### Suggested fix

Either guard the select the way the kernel does, or make the async trigger
safe to call from the switch path. Note that a plain guard would silently
disable the timeline on these architectures, so failing the build with a
clear message may be better than quietly producing no thread events.

### How it was isolated

A matrix of builds, each changing one variable:

| build | boots? |
|---|---|
| baseline, no tracing | yes |
| `SCHED_THREAD_USAGE` + `_ANALYSIS`, no `CONFIG_TRACING` | yes |
| tracing, async, 4 CPUs | no |
| tracing, async, 1 CPU | no |
| tracing, async, without `CONFIG_INIT_STACKS` | no |
| tracing, async, RAM backend instead of UART | no |
| **tracing, sync** | **yes** |

SMP, `CONFIG_INIT_STACKS`, the socket hooks and the UART backend were each
ruled out this way. The statistics-only row is the informative one: it uses
the same runtime-stats machinery but, because of the `if !USE_SWITCH` guard,
does *not* enable the switch instrumentation — and it boots.

---

## Issue 2 — CTF socket tracing hooks dereference their arguments without a NULL check

**Severity:** crash inside the tracer on any failed socket call.
`CONFIG_TRACING_NETWORKING` defaults to `y`.

### What happens

Four CTF socket hooks dereference the caller's `sockaddr` and `addrlen`
without a NULL check and without consulting the call's return value. A socket
call that fails — where those out-parameters need not be valid or filled in —
therefore faults inside the tracer, on a path the untraced application handles
fine.

**Reported from code inspection, not from a reproduction.** I hit a crash in
`net_socket_service` on a traced image and initially attributed it here, but
that turned out to be an unrelated stack overflow in that thread; disabling
`CONFIG_TRACING_NETWORKING` did not prevent it. So this is a latent defect
found while reading the file, not one I have a failing test for. The
inconsistency below is what makes it worth reporting anyway.

### Why

Four hooks in `subsys/tracing/ctf/ctf_top.c` dereference the caller's
`sockaddr` unconditionally, without checking it for NULL and without
consulting the call's return value:

| line | function |
|---|---|
| 373 | `sys_trace_socket_bind_enter()` |
| 388 | `sys_trace_socket_connect_enter()` |
| 607 | `sys_trace_socket_getpeername_exit()` |
| 623 | `sys_trace_socket_getsockname_exit()` |

For example:

```c
void sys_trace_socket_getsockname_exit(int sock, const struct sockaddr *addr,
				       const size_t *addrlen, int ret)
{
	ctf_net_bounded_string_t addr_str;

	(void)net_addr_ntop(addr->sa_family, &net_sin(addr)->sin_addr,
			    addr_str.buf, sizeof(addr_str.buf));

	ctf_top_socket_getsockname_exit(sock, addr_str, *addrlen, ret);
}
```

When `getsockname()` fails, `addr` and `addrlen` need not be valid or filled
in, so the tracer faults on a path the untraced application handles fine.

### This is an inconsistency, not a design choice

Other hooks in the same file already do exactly the right thing:

```c
/* sys_trace_socket_accept_exit(), line ~421 */
	if (addr != NULL) {
		(void)net_addr_ntop(addr->sa_family, &net_sin(addr)->sin_addr,
				    addr_str.buf, sizeof(addr_str.buf));
		port = net_sin(addr)->sin_port;
	}

	if (addrlen != NULL) {
		addr_len = *addrlen;
	}
```

`sys_trace_socket_recvfrom_exit()` has the same guard. The four functions
above simply miss it.

### Suggested fix

Apply the existing `if (addr != NULL)` / `if (addrlen != NULL)` pattern to
the four unguarded hooks. Checking `ret` first would be stricter still, since
a failed call's output arguments are meaningless even when non-NULL.

### Workaround

`CONFIG_TRACING_NETWORKING=n`, at the cost of losing socket events — which
are otherwise valuable for correlating a middleware's RX/TX against
scheduling.


---

## Issue 3 — `CONFIG_THREAD_ANALYZER_AUTO_STACK_SIZE` default of 4096 is far too small; the analyzer overflows its own stack and faults

**Severity:** CPU exception, system halted. Hits the default configuration —
enabling `CONFIG_THREAD_ANALYZER_AUTO` with no other tuning is enough.

### What happens

`CONFIG_THREAD_ANALYZER_AUTO_STACK_SIZE` defaults to 4096, and the analyzer
needs more than twice that. Running the same walk from an application thread
with a 16384-byte stack, the analyzer's own high-water mark is:

```
 asi_thread_stats    : STACK: unused 7344 usage 9040 / 16384 (55 %); CPU: 0 %
```

**9040 bytes against a 4096 default.** That is the report, and it is
arithmetic rather than inference.

It was found because the analyzer died mid-walk at the default, having just
printed its own line at 95 % of 4096:

```
Thread analyze:
 idle 03             : STACK: unused 14112 usage 2272 / 16384 (13 %); CPU: 0 %
 idle 02             : STACK: unused 14112 usage 2272 / 16384 (13 %); CPU: 0 %
 idle 01             : STACK: unused 13776 usage 2608 / 16384 (15 %); CPU: 0 %
 thread_analyzer     : STACK: unused 176 usage 3920 / 4096 (95 %); CPU: 2 %
 ...
<err> os: >>> ZEPHYR FATAL ERROR 0: CPU exception on CPU 3
<err> os: Current thread: 0x1bf980 (thread_analyzer)
<err> os: Halting system
```

**Caveat on that crash specifically:** the image also had an unrelated stack
overflow in another thread at the time, which was corrupting memory, so I
cannot claim in isolation that the fault was the analyzer's own overflow. The
95 %-and-still-walking reading, and the 9040-byte measurement above, are what
the report rests on — the crash is context, not proof.

### Measurement

Running the same walk from an application thread with a 16384-byte stack, the
analyzer's high-water mark is:

```
 asi_thread_stats    : STACK: unused 7344 usage 9040 / 16384 (55 %); CPU: 0 %
```

**9040 bytes** — more than twice `CONFIG_THREAD_ANALYZER_AUTO_STACK_SIZE`'s
default of 4096. With the larger stack the walk completes and repeats
indefinitely with no fault.

Cost scales with the number of threads and with the format string, since
`thread_print_cb()` emits three `printk` lines per thread when
`CONFIG_THREAD_RUNTIME_STATS` and `CONFIG_SCHED_THREAD_USAGE_ANALYSIS` are on.
A configuration with more threads, or with `CONFIG_THREAD_ANALYZER_ISR_STACK_USAGE`
also enabled, needs correspondingly more.

### Suggested fix

Raise the default substantially — 8192 would still be marginal on the
configuration above — and note in the help text that the requirement grows with
thread count and with the runtime-statistics options, since those add two extra
`printk` lines per thread.

It is worth considering whether the analyzer should measure its own headroom
and print a warning rather than faulting, given that its entire purpose is
detecting stack problems.

### Related

- [#76541](https://github.com/zephyrproject-rtos/zephyr/issues/76541) —
  thread_analyzer BUS FAULT with `CONFIG_THREAD_ANALYZER=y` (2024, closed).
  Same symptom class; worth checking whether that report was the same
  underlying cause.
- [#55428](https://github.com/zephyrproject-rtos/zephyr/issues/55428) —
  `CONFIG_THREAD_ANALYZER_AUTO` crash in native_posix (2023, closed).

### Note on how this was found

An earlier reading of this failure attributed it to the analyzer's *timing* —
`thread_analyzer_auto()` does print before its first `k_sleep()`, behind a
`K_THREAD_DEFINE` with a zero start delay, so the first dump always lands
during boot. That is true, and arguably still worth a start-delay option, but
it is not the defect: moving the print to a delayed application thread
reproduced the fault exactly, at the delay instead of at boot. Only the stack
size mattered.

---

## Issue 4 — `k_thread_priority_set()` emits no trace event, so CTF captures cannot show priority changes

**Severity:** silent observability gap. The event is declared and implemented;
it simply never fires, so its absence in a trace is meaningless — and reads as
evidence that no priority change happened.

### What happens

A CTF capture of an application that calls `k_thread_priority_set()` contains
**zero** `thread_priority_set` events, however many times it is called.

### Why

The event exists on the tracing side. `subsys/tracing/ctf/tsdl/metadata`
declares it:

```
event {
	name = thread_priority_set;
	id = 0x12;
	fields := struct {
		uint32_t thread_id;
		ctf_bounded_string_t name[20];
		int8_t prio;
	};
};
```

and `subsys/tracing/ctf/ctf_top.c` implements the hook:

```c
void sys_trace_k_thread_priority_set(struct k_thread *thread)
{
	ctf_bounded_string_t name = { "unknown" };

	_get_thread_name(thread, &name);
	ctf_top_thread_priority_set((uint32_t)(uintptr_t)thread,
				    thread->base.prio, name);
}
```

The path is broken in **three** places, any one of which suppresses the event:

1. `subsys/tracing/ctf/tracing_ctf.h` never defines
   `sys_port_trace_k_thread_priority_set`, so the macro falls through to the
   no-op in `include/zephyr/tracing/tracing.h`. Note the *test* backend does
   map it (`subsys/tracing/test/tracing_test.h`), which is part of why the
   omission is easy to miss — the symbol looks wired if you only grep for its
   name.
2. `z_impl_k_thread_priority_set()` in `kernel/sched.c` never invokes the
   macro, so even a correct mapping would not fire.
3. `include/zephyr/tracing/tracking.h` has no
   `sys_port_track_k_thread_priority_set` no-op. `SYS_PORT_TRACING_OBJ_FUNC`
   expands to *both* a `sys_port_trace_*` and a `sys_port_track_*` call, so
   adding the call site alone fails to LINK:

   ```
   sched.c.obj: in function `z_impl_k_thread_priority_set':
   undefined reference to `sys_port_track_k_thread_priority_set'
   ```

   Note the tracking list does carry `sys_port_track_k_thread_sched_priority_set`
   (the internal `sched_priority_set` variant), which makes the omission of the
   public one easy to overlook.

Contrast `z_thread_mark_switched_in()`, `k_thread_create()` and the semaphore
and mutex families, which all reach their CTF hooks and appear normally in the
same capture.

### Why it matters

Thread priority is exactly the kind of thing a task-timeline capture is used to
verify — "did this thread actually get the priority its configuration
declares?" is a natural question for a real-time system. Today the trace cannot
answer it, and, worse, answers it *incorrectly by omission*: an engineer
reading a capture with no `thread_priority_set` events reasonably concludes
that no priority change occurred.

That happened to us. An application configured a real-time scheduling tier
whose priority is applied with `k_thread_priority_set()`; the empty trace was
read as the tier not being active, and it took reading the runtime's source to
establish that the call does happen and simply is not traced.

### Suggested fix

Both ends. Map the macro in `tracing_ctf.h`:

```c
#define sys_port_trace_k_thread_priority_set(thread)                            \
	sys_trace_k_thread_priority_set(thread)
```

add the tracking no-op in `tracking.h` beside its siblings:

```c
#define sys_port_track_k_thread_priority_set(thread)
```

and invoke the macro from `z_impl_k_thread_priority_set()`:

```c
	bool need_sched = z_thread_prio_set((struct k_thread *)thread, prio);

	SYS_PORT_TRACING_OBJ_FUNC(k_thread, priority_set, thread);
```

Placement matters: the hook reads `thread->base.prio`, so it must run **after**
`z_thread_prio_set()`. Tracing before the store would emit the *old* priority,
which is worse than emitting nothing.

Verified as a local patch against v3.7.0 on `fvp_baser_aemv8r` — all three
hunks are required; omitting the third gives the link error above. Happy to
send it as a PR.

Failing that, removing the unreachable hook and its metadata entry would at
least stop the event from advertising a capability that does not exist.
