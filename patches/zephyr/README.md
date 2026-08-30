<!--
Copyright (c) 2026, Arm Limited.
SPDX-License-Identifier: Apache-2.0
-->

# Local Zephyr patches

Patches this repo applies to `zephyr/` on top of the pinned v3.7.0, beyond the
set `nros setup board` applies. Kept here because `zephyr/` is a submodule and
a provisioning run rewrites its working tree — an unrecorded edit is lost
silently.

Apply with (paths must be ABSOLUTE — `git -C` resolves them relative to
`zephyr/`, not to the repo root):

    for p in "$PWD"/patches/zephyr/*.patch; do git -C zephyr apply "$p"; done

Check whether one is already applied, so re-provisioning is idempotent:

    git -C zephyr apply --check --reverse "$PWD/patches/zephyr/<name>.patch"

## 0001-ctf-trace-k_thread_priority_set.patch

Makes `k_thread_priority_set()` emit its CTF event. Upstream declares the
event in `subsys/tracing/ctf/tsdl/metadata` (id 0x12) and implements the hook
`sys_trace_k_thread_priority_set()` in `ctf_top.c`, but the path is broken at
both ends:

- `subsys/tracing/ctf/tracing_ctf.h` never defines
  `sys_port_trace_k_thread_priority_set`, so the macro resolves to the no-op in
  `tracing.h`. The *test* backend does map it (`tracing_test.h`), which is why
  the omission is easy to miss.
- `z_impl_k_thread_priority_set()` in `kernel/sched.c` never invokes the macro.
- `include/zephyr/tracing/tracking.h` lacks the
  `sys_port_track_k_thread_priority_set` no-op, so adding only the call site
  fails to link (`SYS_PORT_TRACING_OBJ_FUNC` emits a `sys_port_track_*` call
  as well as a `sys_port_trace_*` one).

So a capture contains zero `thread_priority_set` events no matter what the
application does, and the absence reads as "no priority change happened". That
cost us a wrong conclusion about whether a real-time scheduling tier was
active — see `docs/design/rt_evaluation_zephyr.rst`.

The call is placed AFTER `z_thread_prio_set()` because the hook reads
`thread->base.prio`; tracing before the store would record the old priority.

Filed upstream as issue 4 in `docs/design/upstream-zephyr-issues.md`.

## 0003 — allow an out-of-tree tracing backend

`TRACING_BACKEND_DEFINE()` is available to an application, so a backend can be
*registered* out of tree. It cannot be *selected*: `tracing_core.c` picks one
with a compile-time `#elif` chain over the in-tree `CONFIG_TRACING_BACKEND_*`
symbols, and falls back to

```c
#define TRACING_BACKEND_NAME ""
```

`tracing_backend_get("")` then matches nothing, so the registered backend is
never used and tracing silently produces no output. The registration macro is
public API with no way to reach it.

The patch adds `TRACING_BACKEND_CUSTOM` plus a `TRACING_BACKEND_CUSTOM_NAME`
string to the existing choice, and one `#elif` arm. Two hunks, additive: no
in-tree backend changes behaviour.

Needed by phase-8 W8, which routes CTF into an overwrite-oldest RAM ring
(`src/common/diag/trace_ring_backend.c`) so the LAST events survive rather
than the first. Zephyr's own `TRACING_BACKEND_RAM` is fill-once — it stops at
`buffer_full` and goes silent — which is the wrong trade for a recorder meant
to explain a fault, since the interesting events are exactly the ones it drops.

Both of those are worth reporting upstream: the missing selection hook, and
the RAM backend's fill-once behaviour being undocumented at the Kconfig level.

EXIT PLAN — checked 2026-08-30, and it is shorter than written above.
**Upstream `main` has already solved this**, differently and better: the
backend name is a plain `CONFIG_TRACING_BACKEND_NAME` string with per-backend
defaults, and `tracing_core.c` discovers registered backends with
`STRUCT_SECTION_FOREACH`, treating a backend that shares the configured name as
an override. So there is nothing to upstream — this patch is a v3.7.0-LTS
backport need only, and it retires when the Zephyr pin moves.

That is the status of ALL THREE patches here, which is worth stating in one
place:

| patch | upstream status (checked 2026-08-30 against `main`) |
|---|---|
| 0001 priority event | ALREADY FIXED on `main`; backport only |
| 0002 app marker | superseded by the 4.3 instrumentation subsystem; retire, do not upstream |
| 0003 backend selection | ALREADY FIXED on `main`; backport only |

**Nothing here is upstreamable.** All three are v3.7.0 LTS backports and all
three retire when the Zephyr pin moves. That is worth stating plainly because
the opposite was assumed twice in one day: 0003's exit plan said "drop if
upstream gains a selection hook" when it already had one, and 0001 was drafted
as an upstream contribution before `main` was read.

For 0001 specifically, `main` carries exactly the mapping this patch adds, in a
better form:

```c
#define sys_port_trace_k_thread_sched_priority_set(thread, prio)  \
	sys_trace_k_thread_sched_priority_set(thread, prio)
```

It passes `prio` through rather than dropping it, and `ctf_top.c` implements
both that and the `thread`-only variant.

Also checked: of the four issues filed on 2026-08-27, #117636 (thread-analyzer
stack default) is now CLOSED upstream. #117634, #117635 and #117637 remain
open.

## 0001 REVISED 2026-08-30 — one line in the tracing subsystem, not the kernel

The original version of this patch added a `SYS_PORT_TRACING_OBJ_FUNC` call to
`z_impl_k_thread_priority_set()` in `kernel/sched.c`. That was more invasive
than necessary, and it rested on an incomplete reading of the tree.

Stock v3.7.0 already has both ends:

* `z_thread_prio_set()` (`kernel/sched.c:780`) DOES emit
  `SYS_PORT_TRACING_OBJ_FUNC(k_thread, sched_priority_set, thread, prio)`.
* `ctf_top.c` DOES implement `sys_trace_k_thread_priority_set()`.

They are simply not connected: `tracing_ctf.h` maps
`sys_port_trace_k_thread_sched_priority_set(thread, prio)` to an EMPTY macro,
so the event is emitted and then discarded, and the CTF implementation is never
called by anything.

So the fix is one line joining the two, inside the tracing subsystem, with the
kernel untouched:

```c
#define sys_port_trace_k_thread_sched_priority_set(thread, prio) \
        sys_trace_k_thread_priority_set(thread)
```

Verified: a traced FVP boot goes from **zero** `thread_priority_set` events to
**53**. That is more than the original patch would have produced, because
`z_thread_prio_set()` is reached from more paths than the syscall alone.

This also corrects the analysis filed as zephyrproject-rtos/zephyr#117637,
which said the macro is never invoked without noting that a different event IS
emitted and dropped. The conclusion held; the diagnosis pointed at the wrong
fix.
