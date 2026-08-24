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
