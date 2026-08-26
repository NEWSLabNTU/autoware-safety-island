# Phase 5 — legacy-stack cleanup after the nano-ros adoption

Status: **in progress** (started 2026-08-22). Scope: remove what the nano-ros
adoption (phases 3-4) made dead, and replace ASI-local plumbing that nano-ros
now provides. The `main` branch keeps the original stack; this branch is
nros-only (no dual-mode gates — standing rule).

Survey date: 2026-08-22. Legend: [x] done, [ ] planned, [~] deliberately kept
(with the condition that unblocks removal).

## W1 — vendored messages → AMENT environment  [x]

The `autoware_msgs/msg_ros/` tree was byte-identical copies of upstream
packages (verified: 41 of 44 files identical to `/opt/ros/humble` +
`/opt/autoware/<ver>` shares; 2 differed in comments only) with ONE real
local patch: `Trajectory.msg` bounds points at `[<=250]` (the embedded
FixedSequence capacity). Landed:

- [x] `msg_ros/` deleted; `nros_generate_interfaces()` file lists resolve
      through `AMENT_PREFIX_PATH/share/<pkg>/msg/` (same deliberate subset —
      only what the controller consumes is generated).
- [x] The one real patch survives as
      `msg_overrides/autoware_planning_msgs/msg/Trajectory.msg` (local
      resolution wins over ament). Keep the 250-point bound in sync with
      `NROS_SUBSCRIPTION_BUFFER_SIZE`.
- [x] `scripts/sync_msg_ros.sh` + `docs/MSG_PROVENANCE.md` deleted
      (provenance is now the sourced environment).
- [x] `build.sh resolve_ament_env()`: sourced env wins; else existence-gated
      defaults (`/opt/ros/humble`, newest `/opt/autoware/<ver>` — the
      devcontainer layout); fail-early probe for `autoware_planning_msgs`.
      The devcontainer base is `autoware:universe-devel`, so CI has the env.

## W2 — dead submodules  [~]

- [x] `freertos-kernel/` (19 MB) — removed 2026-08-22: zero consumers (the
      posix lane uses `modules/nros/third-party/freertos/kernel`; the legacy
      s32z2 lane uses the NXP PlatformSDK FreeRTOS). Submodule +
      `build-ci.yml`/`release.yml` init lines + CLAUDE.md/AGENTS.md mentions.
      (The `nros setup --source freertos-kernel` spellings that remain are
      nano-ros's SDK source NAME, not this submodule.)
      Working-tree copy deleted from this checkout 2026-08-25, along with the
      orphaned `.git/modules/freertos-kernel` object store (130 MB) and the
      stale `submodule.freertos-kernel.url` entry in `.git/config` — `rm -rf`
      on the working tree alone leaves both behind.
- [x] `cyclonedds/` (24 MB, fork `freertos-s32z2` branch) — removed with W3
      (2026-08-24). CI workflows no longer init it; the release lane's
      CycloneDDS build cache step is gone.
- [~] s32ct_config — S32 Config Tools output (pinmux/clocks). KEPT, moved
      to `actuation_module/src/s32z2_board_glue/s32ct_config` with W3; the
      W5.b hardware session decides its final shape.

## W3 — legacy freertos-s32z2 lane  [x]

`actuation_module/freertos_s32z2/` (208 KB) + `build.sh`'s
`freertos-s32z2-legacy` target + `build_cyclonedds_host()` +
`demo/cyclonedds-s32z2.xml` + `autoware_msgs/msg/*.idl` (49 files, not the
44 first counted) + the idlc `else`-branch in `autoware_msgs/CMakeLists.txt`
+ the `--dds-interface` / `--control-output` build.sh flags.

**W3 IS A SPLIT, NOT A DELETE (audited 2026-08-25).** Five things inside
`freertos_s32z2/` are consumed by the NEW nros lane and must MOVE, not die,
or the retirement breaks a working lane:

| survivor | consumer today |
| --- | --- |
| `vendor_patched/eigen-psincos-int32.patch` | `actuation_module/CMakeLists.txt` (nros lane, configure-time Eigen patch) |
| `vendor_patched/port.c.patch` | `scripts/provision-nxp-freertos.sh` (patched NXP CR52_GIC kernel) |
| `lwip_bringup.c`, `ethif_shim.c` | `src/s32z2_board_glue/` delegates its strong netif overrides to them |
| `s32ct_config` (PBcfg) | expected by W5.b item 5 hardware wiring |
| `README.md` | cited by the glue package and the provisioning script as the NXP download instructions |

What actually dies: `freertos_main.cpp`, `board_init.c`, `cp15_arm.S`, the
linker fragments (`heap_in_sram.ld`, `node_stack_in_sram.ld`,
`netc_bd_no_cacheable.ld`, `discard_unwind.ld`), `newlib_stubs.c`,
`operator_new.cpp`, `pbcfg_shims`, `edge_ecu_peer`, `cmake/`, `scripts/` —
i.e. everything the nros board bundle already provides. Decide each
survivor's new home (probably `src/s32z2_board_glue/`) in the same commit.

2026-08-22: the `freertos-s32z2` build.sh key now names the NROS lane
(phase-4 W5.b items 2-4, link-complete); the legacy lane moved to
`--platform freertos-s32z2-legacy`. Note `lwip_bringup.c`/`ethif_shim.c`
gained a second consumer: `src/s32z2_board_glue/` delegates its strong
netif overrides to them — retirement (this W3) subsumes moving what the
glue keeps into that package.

RETIRED 2026-08-24 in one commit (with W2's `cyclonedds/`), AHEAD of the
W5.b hardware-parity gate by owner decision (no board on hand; item 5 is
deferred and the legacy baseline stays on `main`). Executed as the
2026-08-25 audit table prescribes: the survivors moved into
`src/s32z2_board_glue/` — `board/lwip_bringup.c`, `board/ethif_shim.c`,
`vendor_patched/` (eigen + port.c patches, plus eth_port.c.patch for the
NETC RX path; provision-nxp-freertos.sh and the root CMakeLists
eigen-patch path retargeted), README.md, and the s32ct_config submodule —
and everything the nros board bundle already provides died. build.sh lost
the `freertos-s32z2-legacy` platform, `build_cyclonedds_host()`, and the
`--dds-interface`/`--control-output` flags (legacy-only consumers).

**The deferred item-5 parity need not wait for a board** (scoped
2026-08-26 in `phase-6-emulated-r52-lane.md`): QEMU's `mps3-an536` is a
dual Cortex-R52 machine with the same `lan9118` NIC nano-ros already
drives, so an emulated R52 lane can carry the SOFTWARE half of the proof —
scheduler, GIC/tick, lwIP, Cyclone, the controller — leaving only NETC,
PBcfg, the licensed CR52_GIC port and flash/boot bench-gated.
The concrete W5.b work breakdown

(6 ordered items; 1-3 pre-hardware) lives in phase-4; the upstream gap
analysis lives in nano-ros phase-372 "Exploration findings" — headline:
the netif seam already exists upstream, the NXP CR52 GIC kernel port stays
consumer-provisioned (licensed + needs ASI's Thumb-resume CPSR patch), and
the first Cyclone blocker is the stubbed lwIP multicast join.

## W4 — dual-mode gates + legacy shims  [x]

- [x] Collapse `ASI_USE_NANO_ROS` to nros-only (2026-08-24). The
      2026-08-25 re-count held: **7 files, 18 occurrences** — root
      CMakeLists (2), `node.hpp` (4), `clock.hpp` (1),
      `network_config.hpp` (1), `messages.hpp` (4),
      `controller_node.hpp` (3), `controller_node.cpp` (3); the test
      programs were already off the list (phase-5 W5). The 489-line
      legacy arm of `controller_node.cpp` — the second full controller
      implementation — died with the gate.
- [x] Delete `include/common/dds/` (6 legacy CycloneDDS wrapper headers) —
      done with the gate collapse (2026-08-24). `src/main.cpp` (last
      consumer: the legacy lane) deleted too, per the W5 audit.

## W5 — ASI plumbing replaceable by nano-ros features  [ ]

Candidates found 2026-08-22 (each is its own small work item; none blocks
the others):

- [x] `common/node/node_nros.hpp` poll-shim — DELETED 2026-08-22 (with
      `nros_error.hpp`). The 4 shim-consuming test programs (unit_test,
      dds_pub, dds_sub, dds_loopback_test) now derive
      `nros::ComponentNode` with typed member callbacks and drive
      `nros::init()` + `nros::spin_once()` loops from their own `main()`
      (dispatch on the main thread — the wait helpers spin, not sleep).
      `node.hpp`'s nros arm is a thin alias layer (`AsiNode`,
      `Publisher<M> = nros::Publisher<M>` for the disabled MPC
      debug-publisher member decls); messages.hpp's sentinel `_desc`
      stubs are gone. Dropped with the shim: the spin()/stop()
      thread-management and stop_timer unit tests (executor-owned
      lifecycle now). can_output_test was already node-free.
- [x] `common/logger/` → `nros_log` — DONE 2026-08-26 (unblocked by W3:
      the legacy lane that compiled logger.hpp without nros is gone).
      The `log_*` API surface stays (20+ vendored Autoware TUs); the sink
      is `nros_log_emit_fmt` through the per-platform writer chain, with
      a lazy idempotent `nros_log_init()` for the no_std lanes. Kept
      ASI-side: `log_*_throttle` (upstream has no throttle macros) and
      the CONFIG_LOG_LEVEL compile-time gate. Upstream frictions noted:
      no C-API setter for the per-logger runtime threshold (defaults
      INFO — `log_debug`/PROFILE therefore emit at INFO severity, the
      compile-time gate stays the debug switch), and no SUCCESS-class
      severity (log_success maps to INFO; the CI boot markers grep text,
      not color, so phases 1-4 are unaffected).
- [x] `common/net/network_config.hpp` + `SAFETY_ISLAND_DDS_INTERFACE`
      plumbing — AUDITED 2026-08-22: `SAFETY_ISLAND_DDS_INTERFACE` has no
      remaining consumers (already gone). `configure_network()` stays: it
      is Zephyr board-net bringup (static IP + VLAN tagging + 2-iface +
      DHCP lease wait) delivered as the strong `nros_board_network_wait()`
      override — ASI-board-specific, beyond nano-ros scope. No action.
- [~] SNTP epoch (`platform_init_clock_via_sntp` + `scripts/sntp-server.py`)
      — works, but epoch belongs in nano-ros (RFC-0052 age monitors need
      it too). FILED upstream as nano-ros issue 0758 (2026-08-22):
      optional `epoch_us`/`acquire_epoch` platform-vtable slot, SNTP as
      first provider, server address as a deploy fact. ASI deletes its
      copy when it lands.
- [x] `actuation_module/src/main.cpp` boot banner/init — AUDITED
      2026-08-22: already out of every nros lane (Zephyr + posix + s32z2
      boot through generated entries; the network prologue is the
      `nros_board_network_hook` strong override; boot markers moved into
      the `controller_pkg::Controller` ctor in phase-3). Its only
      remaining consumer is the legacy `freertos-s32z2-legacy` lane
      (`-Dmain=actuation_main`), so the file dies with W3 — nothing to
      fold now.

## W6 — ASI carries production logic; ROS infra belongs to nano-ros  [ ]

The governing principle (2026-08-22): ASI's CMake and glue should be plain
nano-ros macro calls; every ASI-local wrapper around them is either dead
weight or an upstream gap in disguise. W1 already dropped the `_asi_gen`
wrapper — its two reasons-to-exist become upstream friction items:

- [x] `SKIP_INSTALL` parity: STALE BELIEF — the Zephyr module variant has
      accepted-and-ignored the flag since nano-ros Phase 210.E.3.c (filed +
      verified as nano-ros issue 0753, resolved on arrival, 2026-08-22).
      The `_nros_skip_install` lane gate in `autoware_msgs/CMakeLists.txt`
      is dropped; SKIP_INSTALL passes unconditionally.
- [x] Zephyr module idlc discovery ignoring the handed codegen tool —
      filed as nano-ros issue 0754 (2026-08-22). build.sh keeps its PATH
      export until it lands.
- [x] Board-facts deploy passthrough — filed as nano-ros issue 0755
      (2026-08-22): `NanoRosBoardFacts.cmake` should forward the entry's
      DEPLOY as `--deploy`; today a divergent multi-deploy system.toml
      soft-skips facts entirely.
      Also filed the same session: nano-ros 0756 (NROS_MAX_PARAMETERS=256
      Zephyr boot hang — the build.sh 32-pin's unpin condition) and 0757
      (BUFFER_TOO_SMALL silent drop fail-loud — 0749's open half).
- [ ] Longer term: the W5 items above are the same principle applied to
      C++ glue (logger, poll shim, net config, epoch source, boot main).

## Kept deliberately (not cleanup)

- `test/rosbag_test/` (5.9 MB) — recorded-input regression asset; purpose
  review pending, do not delete on size grounds.
- `demo/commands` — raw docker-run equivalents of the compose stack; small,
  useful for single-service debugging. Revisit only if it drifts.
- `zephyr/` submodule + `actuation_module/zephyr_modules/` (west-managed
  HALs) — active Zephyr lanes.
- `--dds-interface` / `--control-output` build.sh flags — still the legacy
  s32z2 lane's interface; die with W3.
