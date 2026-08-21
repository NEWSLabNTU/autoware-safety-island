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
- [ ] `cyclonedds/` (24 MB, fork `freertos-s32z2` branch) — last consumer is
      the legacy `freertos-s32z2` lane (W3). Removed together with it.
- [~] `actuation_module/freertos_s32z2/s32ct_config` — S32 Config Tools
      output (pinmux/clocks). KEPT: likely reusable by the phase-4 W5.b nros
      S32Z2 lane; decide when that lane lands.

## W3 — legacy freertos-s32z2 lane  [~]

`actuation_module/freertos_s32z2/` (freertos_main.cpp, lwIP bringup, ethif
shim, cdds-target build, edge_ecu_peer) + `build.sh` legacy target
+ `build_cyclonedds_host()` + `demo/cyclonedds-s32z2.xml` +
`autoware_msgs/msg/*.idl` (44 files) + the idlc `else`-branch in
`autoware_msgs/CMakeLists.txt`.

2026-08-22: the `freertos-s32z2` build.sh key now names the NROS lane
(phase-4 W5.b items 2-4, link-complete); the legacy lane moved to
`--platform freertos-s32z2-legacy`. Note `lwip_bringup.c`/`ethif_shim.c`
gained a second consumer: `src/s32z2_board_glue/` delegates its strong
netif overrides to them — retirement (this W3) subsumes moving what the
glue keeps into that package.

KEPT until phase-4 W5.b (nros freertos S32Z2 lane: nano-ros phase-372 board
bundle + hardware) reaches boot parity — it is the only S32Z2 build this
branch has. The moment W5.b boots on the board, this whole set goes in one
commit (and W2's `cyclonedds/` with it). The concrete W5.b work breakdown
(6 ordered items; 1-3 pre-hardware) lives in phase-4; the upstream gap
analysis lives in nano-ros phase-372 "Exploration findings" — headline:
the netif seam already exists upstream, the NXP CR52 GIC kernel port stays
consumer-provisioned (licensed + needs ASI's Thumb-resume CPSR patch), and
the first Cyclone blocker is the stubbed lwIP multicast join.

## W4 — dual-mode gates + legacy shims  [ ]

- [ ] Collapse `ASI_USE_NANO_ROS` to nros-only in the 8 gated files
      (`actuation_module/CMakeLists.txt`, `common/node/node.hpp`,
      `common/node/node_nros.hpp`, `common/clock/clock.hpp`,
      `common/net/network_config.hpp`, `autoware_msgs/messages.hpp`,
      `controller_node.{hpp,cpp}`) and in the test programs
      (`test/{unit_test,dds_pub,dds_sub,dds_loopback_test,can_output_test}.cpp`
      — the programs themselves stay: the Zephyr 5-phase CI runs them).
      Blocked with W3: the legacy halves are what the s32z2 lane compiles.
- [ ] Delete `include/common/dds/` (6 legacy CycloneDDS wrapper headers) once
      the gates collapse.

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
- [ ] `common/logger/` → `nros_log` (`nros_error!`/`log.hpp` macros): one
      logging spine instead of two; nros_log reaches no_std targets and
      avoids the native_sim std-stdio hazard class.
      SEQUENCED BEHIND W3 (2026-08-22): `logger.hpp` is compiled by the
      legacy `freertos-s32z2-legacy` lane too, which links no nros — a
      swap now would need a mode gate (banned) or break that lane. Keep
      the `log_*` API surface when it lands (20+ vendored Autoware TUs
      call it); swap the sink to `nros_log_emit_fmt`, and note upstream
      has no throttle macros yet (`log_*_throttle` stays ASI-side).
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
