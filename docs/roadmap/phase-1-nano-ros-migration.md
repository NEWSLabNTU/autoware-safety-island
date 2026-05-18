# Phase 1 - nano-ros migration for Autoware Safety Island

**Goal.** Make ASI a downstream user project of nano-ros. ASI imports
nano-ros as an external dependency and reuses its RMW stack (Cyclone DDS
via `nros-rmw-cyclonedds`). ASI keeps Autoware controller logic
(MPC / PID / CAN) in C++. If a bug surfaces in nano-ros, patch nano-ros —
do not work around it in ASI.

**Status.** Draft, not started. **Revised 2026-05-18** after nano-ros build-
system refactor + completion of nano-ros Phase 117 (Cyclone DDS RMW + ASI
boards), and after the architecture decision to consume nano-ros as an
external dep (vs vendoring a frozen subset).

**Priority.** P0. Branch-level roadmap for `nano-ros` on `newslab/nano-ros`.

**Reference.** See
[`docs/design/nano_ros_migration.rst`](../design/nano_ros_migration.rst)
for gap analysis.

## Architecture

ASI = user project. nano-ros = external dep.

- ASI deletes its vendored Cyclone DDS tree (`cyclonedds/`). Cyclone comes
  from nano-ros's `third-party/dds/cyclonedds/` pin (tag `0.10.5`).
- ASI deletes its raw Cyclone wrapper (`actuation_module/include/common/dds/*`,
  `actuation_module/src/common/dds/*`). The RMW vtable + entity / data-plane
  lives inside nano-ros (`nros-rmw-cyclonedds`).
- ASI keeps `src/autoware/*` (vendored Autoware components — MPC, PID,
  trajectory follower) and CAN / clock / logger helpers under `common/*`.
- `common/node/*` stays as a **thin shim** during migration so
  `controller_node.cpp` and friends compile with minimal edits.
  Long-term it can disappear and consumers can use `nros::Node` directly.
- nano-ros enters the Zephyr build via its native Zephyr module: ASI points
  `ZEPHYR_EXTRA_MODULES` (or a west import) at the nano-ros checkout.
  `CONFIG_NROS=y` + `CONFIG_NROS_CPP_API=y` + `CONFIG_NROS_RMW_CYCLONEDDS=y`
  pulls in everything.

Workflow: clone `nano-ros-autoware` next to ASI (or as submodule / west
project), build, file upstream issues / patches when needed. ASI's CI runs
nano-ros's `just cyclonedds setup` before building ASI.

## Upstream state (nano-ros-autoware, May 2026)

- `nros-rmw-cyclonedds` standalone CMake project at
  `packages/dds/nros-rmw-cyclonedds/`. **No Cargo.toml.** Built via
  `just cyclonedds build-rmw`. Consumed via `find_package(NrosRmwCyclonedds)`
  → `NrosRmwCyclonedds::NrosRmwCyclonedds`. Phase 117.1–117.16 done.
- Cyclone DDS pinned to **tag `0.10.5`** at `third-party/dds/cyclonedds/`
  (matches `ros-humble-cyclonedds` 0.10.5 + `rmw-cyclonedds-cpp` 1.3.4 →
  stock-RMW wire-compat).
- Wire-compat conventions frozen: pub/sub topic `<topic>` → `rt/<topic>`;
  services `rq/<svc>Request` + `rr/<svc>Reply`; type names
  `<pkg>::msg::dds_::<T>_`; service request header inline
  `cdds_request_header_t`. POSIX E2E vs stock `rmw_cyclonedds_cpp` passes
  (117.12).
- Cyclone descriptor codegen is CMake-helper-driven:
  `nros_rmw_cyclonedds_idlc_compile()` +
  `nros_rmw_cyclonedds_add_idl_library()`. Typed C++ structs via
  `nros_generate_interfaces(<pkg> LANGUAGE CPP)`.
- Zephyr boards `nros-board-fvp-aemv8r-smp` and `nros-board-s32z270dc2-r52`
  exist at `packages/boards/`. FVP nros-cpp example wired but **Kconfig
  `CONFIG_NROS_RMW_CYCLONEDDS` not yet defined**; today the Zephyr nros
  module exposes `CONFIG_NROS_RMW_{ZENOH,XRCE,DDS}` (DDS = dust-dds).
- Build orchestration via `just` (modules: `cyclonedds`, `zephyr`,
  `workspace`, …). Tiered `build` ⊂ `build-examples` ⊂ `build-all`;
  `test-unit` ⊂ `test-integration` ⊂ `test` ⊂ `test-all`.
- `nros-cpp` API: `nros::init(locator, domain_id)` → `nros::create_node` →
  `node.create_publisher<M>` / `create_subscription<M>` → spin →
  `nros::shutdown`. Error type `nros::Result`; macros `NROS_TRY`,
  `NROS_TRY_RET`. Zephyr entry shim `NROS_APP_MAIN_REGISTER_ZEPHYR()`.

## What this means for ASI

| Original concern | Resolution |
|---|---|
| Build nano-ros into ASI Zephyr tree | Consume via Zephyr module (`ZEPHYR_EXTRA_MODULES` or west import) |
| Pick first RMW backend | Cyclone DDS chosen upstream; stock-RMW interop done POSIX-side |
| Cyclone-on-Zephyr feasible? | Outstanding upstream gap (Phase 1D owns); FVP / S32Z boards already exist |
| ASI .idl interop | Downconvert to ROS `.msg` (preferred) or feed direct IDL through `nros_rmw_cyclonedds_idlc_compile` |
| Cyclone version drift | **Delete ASI vendored Cyclone**. Use nano-ros's 0.10.5 pin |
| Maintain `common/dds` | Delete. `nros-rmw-cyclonedds` replaces it |

## Parallel Work Groups

| Group | Phase doc | Ownership | Output |
|---|---|---|---|
| A | [1A build system spike](phase-1A-build-system-spike.md) | ASI Zephyr/CMake | nano-ros module discovered in ASI build; minimal smoke compiles |
| B | [1B interface codegen](phase-1B-interface-codegen.md) | ASI + nano-ros codegen | Generated C++ bindings + Cyclone descriptors for ASI messages |
| C | [1C node adapter](phase-1C-node-adapter.md) | ASI C++ app layer | Thin `common/node` shim on top of `nros::Node`; `common/dds` deleted |
| D | [1D middleware backend](phase-1D-middleware-backend.md) | nano-ros Zephyr RMW glue | `CONFIG_NROS_RMW_CYCLONEDDS=y` validated on FVP; patches in `~/repos/nano-ros-autoware` |
| E | [1E tests and demo](phase-1E-tests-demo.md) | ASI tests/demo | parity tests vs stock RMW + demo closure |

A unblocks B–D. E runs continuously.

## Work Items

- [ ] **1.1 - Lock branch/workspace contract.**
  ASI branch `nano-ros` tracks `newslab/nano-ros`. Use
  `~/repos/nano-ros-autoware` for nano-ros patches; treat
  `~/repos/nano-ros` as read-only reference (has unrelated local changes).
- [ ] **1.2 - Import nano-ros as external dep.**
  Pick (a) git submodule under ASI, (b) west project in
  `actuation_module/west.yml`, or (c) `ZEPHYR_EXTRA_MODULES` env handoff.
  Prefer (b) or (c) so Zephyr module discovery is automatic. Document the
  reproducible checkout path.
- [ ] **1.3 - Delete ASI vendored Cyclone DDS.**
  Remove `cyclonedds/` from ASI. Drop `build.sh`'s `build_cyclonedds_host`
  step. Cyclone now comes from nano-ros's bundled 0.10.5 + its
  `just cyclonedds setup`.
- [ ] **1.4 - Delete `common/dds` raw wrapper.**
  Remove `actuation_module/include/common/dds/*` and
  `actuation_module/src/common/dds/*`. The RMW layer lives in
  `nros-rmw-cyclonedds`; ASI talks to it through `nros-cpp`.
- [ ] **1.5 - Generate required ASI interfaces.**
  Emit nros-cpp bindings (`nros_generate_interfaces`) + Cyclone descriptors
  (`nros_rmw_cyclonedds_add_idl_library`) for trajectory, odometry,
  steering, acceleration, operation mode, control command, and debug
  timing messages.
- [ ] **1.6 - Adapter shim or direct port.**
  Either keep `common/node` as a thin shim over `nros::Node` (preserves
  controller call sites) or port `controller_node.cpp` directly to
  `nros::Node`. Adapter is the cheaper migration step; direct port is the
  cleaner end state.
- [ ] **1.7 - Port controller communication.**
  Move `controller_node.cpp` pub/sub setup onto the adapter (or
  `nros::Node`). Keep MPC / PID / CAN behavior unchanged except for
  message type conversions. Use stock-RMW topic prefixes + IDL type names.
- [ ] **1.8 - Land Cyclone-on-Zephyr RMW glue (upstream).**
  Add `CONFIG_NROS_RMW_CYCLONEDDS` to the nano-ros Zephyr module, wire the
  Cyclone build for Zephyr (FVP + S32Z), and flip the FVP example's
  Kconfig symbol. Patches in `~/repos/nano-ros-autoware`.
- [ ] **1.9 - Restore smoke tests.**
  Rebuild DDS round-trip, publisher, subscriber, CAN, and rosbag
  comparison tests against the nano-ros path. Mirror nano-ros's
  `nros-tests` per-platform port + nextest group pattern.
- [ ] **1.10 - Cut PR-ready docs.**
  Update quickstart / testing / troubleshooting docs: how to fetch
  nano-ros, `just`-driven workflow, host ROS 2 Humble + stock
  `rmw_cyclonedds_cpp` interop setup, deleted-files notice.

## Acceptance Criteria

- [ ] ASI repo no longer ships `cyclonedds/` vendor tree or `common/dds`.
- [ ] `./build.sh` builds the default FVP target with `CONFIG_NROS=y` +
      `CONFIG_NROS_CPP_API=y` + `CONFIG_NROS_RMW_CYCLONEDDS=y`,
      consuming nano-ros from an external checkout.
- [ ] Required ASI message types are generated as both nros C++ bindings
      and Cyclone descriptors, used by the controller.
- [ ] Controller publishes `/control/trajectory_follower/control_cmd` over
      Cyclone-on-Zephyr and is observed by stock `ros2 topic echo` (Humble
      + `rmw_cyclonedds_cpp`).
- [ ] CAN-only and DDS-and-CAN output modes keep existing behavior.
- [ ] S32Z (`s32z270dc2_rtu0_r52@D`) builds to ELF parity with FVP.
- [ ] `newslab/nano-ros` branch has no unrelated changes mixed into the PR.
- [ ] All nano-ros-side patches landed (or queued) in
      `~/repos/nano-ros-autoware`, not embedded as ASI workarounds.
