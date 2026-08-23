<!--
Copyright (c) 2026, Arm Limited.
SPDX-License-Identifier: Apache-2.0
-->

# Upstream Zephyr issue drafts

Two defects found while bringing up CTF tracing on the FVP lane
(`docs/design/rt_evaluation_zephyr.rst`). Both are in Zephyr itself, neither
is ASI-specific, and both reproduce on any board with the same properties.
Drafted here for filing at <https://github.com/zephyrproject-rtos/zephyr>.

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

With CTF tracing enabled on a networked application, the image faults in the
`net_socket_service` thread. The last event in the captured stream is
`socket_getsockname_enter`.

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
