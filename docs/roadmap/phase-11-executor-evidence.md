# Phase 11 — evidence for nano-ros's deadline-driven executor

Status: **checkpoint (2026-09-11)**, in progress. This is the ASI side of nano-ros
phase-436 (`modules/nros/docs/roadmap/phase-436-poll-wake-revision-deadline-driven-executor.md`,
which has its own checkpoint block at the top). Read both before resuming.

**Scope.** Show, on ASI's FVP image, that nano-ros's executor probes measure what they
claim to measure, under real load. The probes are the release-jitter readout, park
attribution and stack headroom. Then use them to find why the control loop falls behind
its declared cadence when Autoware traffic arrives.

## State at the checkpoint

`nano-ros` pins nano-ros `af14492fe`, which has E3 and E4. The branch commits:

| commit | what |
|---|---|
| `d63f19f` | pin `af14492fe` (both pins: gitlink and `west.yml`); also added `CONFIG_INIT_STACKS=y` |
| `ff12002` | **reverts** that `CONFIG_INIT_STACKS=y`. E4 still leaves a ~33 ms stack scan once a second (below) |
| `b8378ae` | CTF contract check selects the control timer by name and judges periods to one tick |
| `0281ab1` | `build.sh --run` starts the model before touching cargo |
| `051178f` | `run-tap-demo.sh` boots the FVP island with `build.sh --run`, not west's rebuilding run target |

**Waiting on branch `wip/a3-rt-probe-readout`: the per-window `rt-probe:` readout**
(`CONFIG_ASI_RT_PROBE_REPORT`, on in `tracing_stats.conf`). It is verified, but it cannot
land yet. It needs nano-ros's `nros_cpp_executor_clear_release_jitter_stats`, on nano-ros
main from `64a350ce4`. Every commit that has it also has phase-427 W4's deletion of
`nros::ComponentNode` (`1f3b88aec`), and `controller_pkg::Controller` derives from
`ComponentNode`. **The port to nano-ros's single node type comes first.**

## What the FVP runs showed

The evidence is gitignored and local: `log/a3/`. It holds the CTF capture, the island
logs, `a3-analyze.sh` and `probe-phases.py`. The probe and CTF both use CNTVCT
(`k_cycle_get_64` / `_32`), so the comparisons are self-consistent. They are not absolute
latency: the FVP is not cycle-accurate, and its counter drifts during WFI.

* **The readout agrees with two independent sources.** During a ~12 s collapse at traffic
  onset, it showed ~300 ms spin intervals. The controller's own log lines came 295–366 ms
  apart, so the 30 ms control timer was running at ~3.3 Hz. The trace shows `idle` never
  ran in that span, and `main` was preempted by `rx_q[0]` and `recvUC`.
* **Under load the loop runs far below its declared cadence.** With the tier declaring
  5 ms: traced run 32.5 wakes/s, untraced 8.9 wakes/s. `control_cmd` ran at 8–13.5 Hz,
  against ~19 Hz+ healthy.
  * Ruled out: CTF (the untraced run was worse) and the RX-buffer burst (absent in the
    untraced run).
  * Untested: the controller's three synchronous INFO lines per cycle, and MPC cost under
    preemption. The trace shows the control callback taking a median 24 ms of its 30 ms
    period.
* **E4's scan, measured.** Without E4, painted builds scanned the whole unused stack on
  every spin: 26.7 wakes/s against 162 with E4. With E4, one ~32.6 ms `main` slice about
  every 1.003 s remains, and that is the constant ~33 ms outlier in every readout window.
  `main` uses 65 KiB idle and 149 KiB loaded, of 512 KiB.

## Open items, ASI side

1. **Port off `nros::ComponentNode`** (nano-ros phase-427 W4). Then pin past `64a350ce4`
   and merge `wip/a3-rt-probe-readout`.
2. **The loaded logging test.** Quiet the controller's per-cycle INFO lines, not the log
   mode, and rerun `ASI_DEMO_BUILD_ARGS=--trace-stats scripts/run-tap-demo.sh --drive`.
   It needs a run where autonomous mode engages: 2 of the last 3 did. The third was
   refused 10/10 on `duplicated_node_checker` / `route_state`.
3. **Turn `CONFIG_INIT_STACKS` back on once nano-ros E5 lands.** E5 makes the headroom
   query O(1) when the stack has not grown.
4. **Size `main`'s stack from measurement.** It is 512 KiB, and 149 KiB is used under
   load. A smaller stack also shortens any scan.
5. **Upstream Zephyr items** for `docs/design/upstream-zephyr-issues.md`:
   * `log_output.c:122`: `out_func` checks for a full buffer and then advances the offset
     as two separate steps. Deferred mode crashed there on two CPUs, fatal under
     `CONFIG_ASSERT=y`.
   * The pre-existing `tid … is in use!` errors: 7 at boot, from `k_thread_stack_free`
     on live threads.
6. **Raise with nano-ros:** its Cyclone snippet forces `CONFIG_LOG_MODE_IMMEDIATE=y` "to
   keep Cyclone init failures legible". Every Cyclone Zephyr image therefore logs
   synchronously on the calling thread.

## Hazards that cost time here

* **Parallel sessions share `~/.cargo`.** Any cargo step can wait minutes on the
  package-cache lock. `build.sh --run` and the demo no longer run cargo to launch a model.
* **`git status` in this repo takes minutes**, because it recurses into
  `modules/nros/third-party/px4/PX4-Autopilot`. Never run a second git command on this
  index while one is in flight: a stale `index.lock` follows.
* **Never test FVP liveness with `pgrep -f FVP_BaseR_AEMv8R`.** It matches the checking
  shell's own command line. Use `pgrep -x FVP_BaseR_AEMv8`, the kernel's truncated
  process name.
* **`log/tap-demo-*.log` is overwritten on every demo run.** Copy it out first. Earlier
  runs are kept in `log/pre-a3/` and `log/a3/`.
