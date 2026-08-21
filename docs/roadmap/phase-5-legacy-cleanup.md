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

- [ ] `common/node/node_nros.hpp` poll-shim (`SubscriptionHandler::poll()`
      over `try_recv`) — superseded by the executor-dispatch `ComponentNode`
      facade the controller already uses; remaining consumers are the test
      programs. Port them to `ComponentNode`, delete the shim.
- [ ] `common/logger/` → `nros_log` (`nros_error!`/`log.hpp` macros): one
      logging spine instead of two; nros_log reaches no_std targets and
      avoids the native_sim std-stdio hazard class.
- [ ] `common/net/network_config.hpp` + `SAFETY_ISLAND_DDS_INTERFACE`
      plumbing — partially superseded by nano-ros boot-config env rungs
      (#206); audit what is still ASI-specific (CAN stays ASI).
- [ ] SNTP epoch (`platform_init_clock_via_sntp` + `scripts/sntp-server.py`)
      — works, but epoch belongs in nano-ros (`ExecutorConfig::epoch_us` /
      RFC-0052 age monitors need it too). Candidate upstream contribution:
      a platform SNTP epoch source; ASI then deletes its copy.
- [ ] `actuation_module/src/main.cpp` boot banner/init — much of it is now
      the generated entry's job; fold what remains into board hooks.

## W6 — ASI carries production logic; ROS infra belongs to nano-ros  [ ]

The governing principle (2026-08-22): ASI's CMake and glue should be plain
nano-ros macro calls; every ASI-local wrapper around them is either dead
weight or an upstream gap in disguise. W1 already dropped the `_asi_gen`
wrapper — its two reasons-to-exist become upstream friction items:

- [ ] `SKIP_INSTALL` parity: the canonical `nros_generate_interfaces()`
      needs it for in-app aggregations; the Zephyr module variant misparses
      it as a message path. One vocabulary, both variants — then the
      `_nros_skip_install` lane gate in `autoware_msgs/CMakeLists.txt` dies.
      File as a nano-ros issue.
- [ ] The Zephyr module's idlc discovery starts from `find_program(nros)`
      on PATH even when the build already passes `-D_NANO_ROS_CODEGEN_TOOL`
      — so consumers must export PATH themselves (build.sh does, since W1's
      clean reconfigure exposed it). The module should reuse the tool it was
      handed. File as a nano-ros issue.
- [ ] Board-facts `--deploy` disambiguation: with two deploys naming one
      board, `nros ws board-facts` refuses; the zephyr module should pass
      its deploy through instead of surfacing the refusal to the consumer
      build. File as a nano-ros issue.
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
