# Phase 1 - nano-ros migration for Autoware Safety Island

**Goal.** Make ASI a downstream user project of nano-ros. ASI imports
nano-ros as an external dependency and reuses its RMW stack (Cyclone DDS
via `nros-rmw-cyclonedds`). ASI keeps Autoware controller logic
(MPC / PID / CAN) in C++. If a bug surfaces in nano-ros, patch nano-ros —
do not work around it in ASI.

**Status.** **MVP build chain GREEN as of 2026-05-19.**
`./build.sh` (no flag — unified default after Phase 1.3/1.4)
produces a linked `build/actuation_module/zephyr/zephyr.elf`
(**1.0 MB text**, 9 KB data, 1.86 MB BSS) for the FVP target,
against upstream nano-ros pinned at `70ab6227d` on
`NEWSLabNTU/nano-ros` main. Vendored Cyclone DDS + raw `common/dds`
wrapper deleted (commit `15aeca3`). Runtime on FVP/AVH is the next
gate (no FVP simulator in dev container — handed off to the user).
Originally drafted after the nano-ros build-system refactor + nano-ros
Phase 117 (Cyclone DDS RMW + ASI boards), and after the architecture
decision to consume nano-ros as an external dep (vs vendoring a
frozen subset).

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

## Build chain verified

`./build.sh` reaches `Linking CXX executable zephyr/zephyr.elf` through
these stages (commit `9302304` / pin `70ab6227d`):

1. `west update` fetches nano-ros into `modules/nros/` (revision pinned
   in `actuation_module/west.yml`).
2. `scripts/bootstrap-nano-ros-shim.sh` (idempotent, run from inside
   `build.sh`) builds `nros-codegen` from
   `modules/nros/packages/codegen/packages/` (workspace edited to drop
   `nros-cli-core` / `nros-cli` — they reference an absent `play_launch`
   sibling tree) and stages it under
   `modules/nros/build/install/{bin,share,lib/cmake/NanoRos}/`.
3. `build.sh` invokes `west build` with
   `-D_NANO_ROS_CODEGEN_TOOL=$ROOT_DIR/modules/nros/build/install/bin/nros-codegen`
   (overrides `nano_ros_overlay.conf`'s container-bind-mount default
   so the host path resolves on local dev as well).
4. `nros_generate_interfaces()` emits C++ + Rust FFI for the 10
   vendored ROS 2 Humble packages.
5. Per-package Rust FFI staticlibs compile (`cargo build --target
   aarch64-unknown-none --release`).
6. `nros-cpp` + `nros-c` Rust libs compile against the Zephyr SDK
   aarch64 toolchain.
7. Zephyr core + drivers + libc + posix subsys link.
8. User C++ TUs compile (`controller_node` + MPC + PID + `main` + net).
9. Final ELF link with `-Wl,--allow-multiple-definition` (cross-package
   FFI staticlibs duplicate codegen-emitted symbols; bodies are
   byte-identical so the linker drops dupes safely — same trick
   nano-ros uses for native_sim).

ELF metrics (`fvp_baser_aemv8r_smp`, commit `9302304`):
text **1,006,456 B** (-39% vs pre-1.3/1.4) / data 9,444 /
bss 1,858,247 / AArch64 EXEC. Fits in 64 MB FLASH (0.00% used) +
128 MB RAM (2.14% used).

### Devcontainer (commit `97188b2` + `bfbbdeb`)

Image runs as a non-root `dev` user behind fixuid; launcher passes
`--user $(id -u):$(id -g)` so files created in the bind-mount + `$HOME`
are owned by the host UID (no more `sudo chown` after a build run).
Local-image autobuild (`asi-devcontainer-local:fixuid`) until the
registry tag rebuild lands; override via
`ASI_DEVCONTAINER_IMAGE=ghcr.io/.../autoware-safety-island:devcontainer`.

### Upstream patches landed during bring-up

All 17 nano-ros bring-up patches merged to `NEWSLabNTU/nano-ros` main
on or before `2ea2e6bf` (pin bumped to `70ab6227d` on 2026-05-19; the
40-commit delta is unrelated NuttX / codegen / CI work). Key patches:

| Category | Examples |
|---|---|
| Codegen scope | `59ab7c6a` propagate `${target}_GENERATED_RS_FILES`; `0f7b9a2e` declare `nros_generated.h` byproduct; `80d32726` stage `nros-serdes` for FFI |
| Zephyr port | `f7b69f5f` gate cxx-compat on `CONFIG_PICOLIBC`; `defb2260` drop `.ipv4` sub-struct; `29a6de92` IGMP fallback; `bc7fcacc` cross-CC env for `cc` crate |
| Cyclone-on-Zephyr | shm_stubs, iceoryx field/fn stubs, `_cdds_zephyr_overrides` wiring (commits `b9819060`..`2ea2e6bf`) |

**`NEWSLabNTU/colcon-nano-ros` main (codegen submodule):**
- `2a88fae` `fix(rosidl-codegen): emit intra-pkg includes for fully-qualified same-pkg refs`

### Open items before runtime gate

- Cyclone-on-Zephyr Kconfig **DONE** (`CONFIG_NROS_RMW_CYCLONEDDS=y`
  in `actuation_module/nano_ros_overlay.conf`; activated upstream by
  commits `9093a4af`..`2ea2e6bf`).
- `mpc_lateral_controller.cpp::publishPredictedTraj` body is the
  placeholder it has always been (was gated, now unconditional after
  Phase 1.3/1.4 — pending a `TrajectoryMsg` std::vector wrapper →
  nros `FixedSequence` raw conversion helper). The publisher is
  debug-only and never `create_publisher`'d in current ASI, so this
  is a follow-up not a blocker.
- AVH device config + Arm Fast Models access still required for
  runtime smoke (work item 1.9).

## Work Items

- [x] **1.1 - Lock branch/workspace contract.**
  ASI branch `nano-ros` tracks `newslab/nano-ros`. Use
  `~/repos/nano-ros-autoware` for nano-ros patches; treat
  `~/repos/nano-ros` as read-only reference (has unrelated local changes).
- [x] **1.2 - Import nano-ros as external dep.**
  Pick (a) git submodule under ASI, (b) west project in
  `actuation_module/west.yml`, or (c) `ZEPHYR_EXTRA_MODULES` env handoff.
  Prefer (b) or (c) so Zephyr module discovery is automatic. Document the
  reproducible checkout path.
- [x] **1.3 - Delete ASI vendored Cyclone DDS.** (commit `15aeca3`)
  Removed `cyclonedds/` submodule + `.gitmodules` entry + `build.sh`'s
  `build_cyclonedds_host` step + `cyclonedds_config.cmake`. Cyclone now
  comes from nano-ros's bundled 0.10.5 via the Zephyr module wiring.
- [x] **1.4 - Delete `common/dds` raw wrapper.** (commit `15aeca3`)
  Removed `actuation_module/include/common/dds/*` and
  `actuation_module/src/common/dds/*`. The RMW layer lives in
  `nros-rmw-cyclonedds`; ASI talks to it through `nros-cpp`. Also
  dropped the `ASI_USE_NANO_ROS` CMake toggle + every `#ifdef` site
  + legacy idlc CMake path in `autoware_msgs/CMakeLists.txt`.
- [x] **1.5 - Generate required ASI interfaces.**
  Emit nros-cpp bindings (`nros_generate_interfaces`) + Cyclone descriptors
  (`nros_rmw_cyclonedds_add_idl_library`) for trajectory, odometry,
  steering, acceleration, operation mode, control command, and debug
  timing messages.
- [x] **1.6 - Adapter shim or direct port.**
  Either keep `common/node` as a thin shim over `nros::Node` (preserves
  controller call sites) or port `controller_node.cpp` directly to
  `nros::Node`. Adapter is the cheaper migration step; direct port is the
  cleaner end state.
- [x] **1.7 - Port controller communication.** (Compile-time done;
  one debug publisher gated behind `#ifndef ASI_USE_NANO_ROS` pending
  TrajectoryMsg→Raw helper.)
  Move `controller_node.cpp` pub/sub setup onto the adapter (or
  `nros::Node`). Keep MPC / PID / CAN behavior unchanged except for
  message type conversions. Use stock-RMW topic prefixes + IDL type names.
- [x] **1.8 - Land Cyclone-on-Zephyr RMW glue (upstream).**
  17 patches merged to `newslab/main`; `CONFIG_NROS_RMW_CYCLONEDDS=y`
  active in `actuation_module/nano_ros_overlay.conf`. Both FVP and
  S32Z still need runtime validation (1.9).
- [ ] **1.9 - Restore smoke tests.**
  Rebuild DDS round-trip, publisher, subscriber, CAN, and rosbag
  comparison tests against the nano-ros path. Mirror nano-ros's
  `nros-tests` per-platform port + nextest group pattern. Includes
  first-boot smoke on AVH / FVP (`nros::init` + first publish
  observed by host `ros2 topic echo`).
- [ ] **1.10 - Cut PR-ready docs.**
  Update quickstart / testing / troubleshooting docs: how to fetch
  nano-ros, `west update`, fixuid devcontainer launch, host ROS 2
  Humble + stock `rmw_cyclonedds_cpp` interop setup, deleted-files
  notice.

### Post-1.4 follow-ups (not blockers)

- [ ] **1.11 - FreeRTOS POSIX simulator port to nano-ros.** Job
  retired from CI with the Cyclone submodule; tree preserved at
  `actuation_module/freertos/` for archaeology. Re-enable once
  nano-ros's POSIX platform backend is exercised here.
- [ ] **1.12 - Devcontainer registry rebuild.** Push the fixuid
  image to `ghcr.io/autowarefoundation/autoware-safety-island:devcontainer`
  via the existing publish pipeline so teammates don't need the
  local autobuild fallback.
- [ ] **1.13 - `TrajectoryMsg` → `FixedSequence` raw helper.**
  Unblocks `publishPredictedTraj` real body.

## Acceptance Criteria

- [x] ASI repo no longer ships `cyclonedds/` vendor tree or `common/dds`.
      (commit `15aeca3`)
- [x] `./build.sh` builds the default FVP target with `CONFIG_NROS=y` +
      `CONFIG_NROS_CPP_API=y` + `CONFIG_NROS_RMW_CYCLONEDDS=y`,
      consuming nano-ros from an external checkout. (commit `9302304`)
- [x] Required ASI message types are generated as both nros C++ bindings
      and Cyclone descriptors, used by the controller.
- [ ] Controller publishes `/control/trajectory_follower/control_cmd` over
      Cyclone-on-Zephyr and is observed by stock `ros2 topic echo` (Humble
      + `rmw_cyclonedds_cpp`). **(runtime gate — work item 1.9)**
- [ ] CAN-only and DDS-and-CAN output modes keep existing behavior.
- [ ] S32Z (`s32z270dc2_rtu0_r52@D`) builds to ELF parity with FVP.
- [x] `newslab/nano-ros` branch has no unrelated changes mixed into the PR.
- [x] All nano-ros-side patches landed in `NEWSLabNTU/nano-ros` main, not
      embedded as ASI workarounds (verified at pin `70ab6227d`).
