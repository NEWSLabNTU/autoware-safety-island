# Phase 2 — nano-ros workspace-mode migration

**Status.** Proposed (2026-06-11). Phase 1 (single-fused-app migration
onto nano-ros) is GREEN; nano-ros is in bug-fixing mode and cleared
for full ASI adoption. This phase moves `actuation_module` from the
pre-212 single-app shape onto nano-ros **workspace mode** (Node pkg +
Bringup pkg + C++ Entry pkg), with identity resolved declaratively.

**Goal.** Restructure `actuation_module` so the `controller` node, its
topology, and its board deployment are **declarative** — a Bringup pkg
`system.toml` + `launch.xml` define names/topics/remaps, a C++ Entry
pkg boots it via `NROS_MAIN` + `nano_ros_use_board(fvp-aemv8r-smp)`,
and the imperative `main.cpp` boot disappears.

**Depends on (nano-ros, ASI-driven).**
- **nano-ros Phase 215** — board-crate import (`board.cmake` +
  `nano_ros_use_board()`; `01ef6bd1a`/`2b9a909c9` landed, remainder
  215.C–G/I open).
- **nano-ros Phase 236** — C++ Entry-pkg embedded board adapter +
  real NodeContext runtime (G1+G2). ASI is the reference consumer;
  Phase 236 lifts ASI's working `common/node` shim under the
  declarative seam. **This is the hard dependency** — until 235 lands,
  the C++ Entry path has no live embedded runtime.
- Design of record: nano-ros RFC-0032 §8a, RFC-0024 (workspace layout).

**Priority.** P2 — Phase 1 already delivers a working binary; workspace
mode is an ergonomics + future-multi-node investment, not a capability
unlock. Forward-looking value: adding perception/planning nodes later
becomes declarative instead of imperative `main.cpp` surgery.

---

## Overview

ASI today is a **single fused Zephyr binary** with one ROS node
(`controller`), names/topics hardcoded in C++. Workspace mode wants the
topology declarative. The mapping is clean because ASI is single-node
and the 8 autoware components are *libraries*, not nodes:

| ASI today | Workspace-mode target |
|---|---|
| `controller` node (`Node("controller", …)` in C++ ctor) | **Node pkg** `controller_pkg` carrying the node decl |
| 8 autoware component libs (universe_utils, MPC, PID, …) | plain CMake libs the Node pkg links — unchanged |
| topics hardcoded in `create_publisher/subscription` | `launch.xml` `<node>` + `<remap>` |
| `main.cpp`: network → `nros::init` → `new Controller()` → spin | **C++ Entry pkg** `NROS_MAIN(<Board>, "controller_bringup:system.launch.xml")` |
| hand-glued `EXTRA_CONF_FILE`/`DTC_OVERLAY`/`BOARD` | `nano_ros_use_board(fvp-aemv8r-smp)` (Phase 215) |
| `common/node` shim over `nros::Node` | becomes the nano-ros NodeContext runtime (Phase 236.A/B) — upstreamed |

## Identity gaps (must close)

| # | gap | fix |
|---|---|---|
| **I1** | Component class violates the `<pkg-dir>::<UserClass>` rule (`nros check` enforces). Pkg dir `autoware_trajectory_follower_node`, class `autoware::motion::control::trajectory_follower_node::Controller`. | Register the controller under a pkg-dir-matching class alias (a thin `controller_pkg::Controller` registration shim), or rename the Node pkg dir to match. Decide in 2.A. |
| **I2** | Node name `"controller"` baked into the C++ ctor. | Lift to `system.toml [[component]].name` / launch `<node name>`; the Node pkg reads its name from the resolved context, not a literal. |
| **I3** | Topic names hardcoded in `create_publisher/subscription`. | Move to `launch.xml` `<remap from=… to=…>`; default topics stay as the node's declared defaults. |
| I4 | (clean) the 8 components are deps, not nodes — only `controller` is a node. | no change — they stay plain libs. |

## Work Items

### 2.A — Node pkg extraction + identity alignment (I1–I3)

- [ ] **2.A.1** Carve `controller` into a Node pkg
      (`actuation_module/src/.../controller_pkg/` or equivalent) with a
      `package.xml` + the `[package.metadata.nros.node]` / C++
      `NROS_NODE`-equivalent class decl.
- [ ] **2.A.2** Resolve **I1** — pick alias-shim vs dir-rename so
      `class = <pkg-dir>::Controller` passes `nros check`.
- [ ] **2.A.3** Resolve **I2/I3** — node name + the 5 sub / 3 pub
      topics move out of code into the Bringup pkg's launch file;
      keep the current strings as declared defaults so behaviour is
      unchanged.

### 2.B — Bringup pkg (declarative topology)

- [x] **2.B.1** Author `controller_bringup/` — `package.xml` +
      `system.toml` (`[system]` rmw=cyclonedds, domain_id=0;
      `[[component]]` pkg=controller_pkg, name=controller) +
      `launch/system.launch.xml` (the `<node>` + `<remap>` set) +
      `config/` for params.
      **Done 2026-06-11.** Pkg at `actuation_module/src/controller_bringup/`
      (sibling of `controller_pkg`, RFC-0024 §11.2 `src/<pkg>` layout):
      `package.xml` (format 3, pure-declarative — no buildtool_depend per
      Phase 212.J.5; `exec_depend` on controller_pkg), `system.toml`
      (`[system]` name=controller_bringup rmw=cyclonedds domain_id=0
      default_launch=system.launch.xml; `[[component]]`
      class=controller_pkg::Controller name=controller; `[deploy.fvp]`
      kind=zephyr target=fvp_baser_aemv8r_smp board=fvp-aemv8r-smp),
      `launch/system.launch.xml` (the `<node>` + 8 `<remap from=default
      to=default>`), `config/params.yaml`. **Verified:** all files
      well-formed (XML/TOML/YAML parse); the 8 `from=` topics diff-match
      `node_identity.hpp` exactly (8/8). `nros check --bringup` PASSES
      ("pure declarative"). `nros plan` parses the launch through the real
      `play_launch_parser` and resolves the full topology (node=controller,
      pkg=controller_pkg, exec=controller, all 8 remaps, control_output
      param) — only remaining error is `missing-source-metadata` for the
      not-yet-built controller_pkg component (a 2.C/devcontainer build
      artifact, expected).
- [x] **2.B.2** Map ASI's DDS-only / CAN-only / DDS+CAN output modes
      onto launch args (`$(var control_output)`), replacing the
      Kconfig `choice CONTROL_CMD_OUTPUT_MODE`.
      **Done 2026-06-11 (launch-arg surface established; Kconfig deletion
      deferred to 2.C).** `launch/system.launch.xml` declares
      `<arg name="control_output" default="DDS_ONLY"/>` and passes it to
      the node as `<param name="control_output" value="$(var control_output)"/>`.
      Mapping from the retiring `choice CONTROL_CMD_OUTPUT_MODE`:
      `DDS_ONLY` ⇒ `CONTROL_CMD_OUTPUT_DDS_ONLY` (default),
      `CAN_ONLY` ⇒ `CONTROL_CMD_OUTPUT_CAN_ONLY`,
      `DDS_AND_CAN` ⇒ `CONTROL_CMD_OUTPUT_DDS_AND_CAN`. Per the
      `workspace_mode.rst` open question, CAN is a hardware sink (not a ROS
      topic), so the mode is a node **param**, not a `<remap>` — it stays
      outside ROS-node identity. The derived Kconfig booleans
      (`CONTROL_CMD_DDS_OUTPUT`, `CONTROL_CMD_CAN_OUTPUT`) become the
      node's interpretation of the param value. `config/params.yaml`
      mirrors the knob for a params-file deploy. The Kconfig `choice`
      itself is NOT yet deleted (2.C scope); only the launch-arg surface
      is established here.

### 2.C — C++ Entry pkg + board import

**Precondition done (2026-06-11).** `actuation_module/west.yml` nano-ros
pin bumped `70ab6227d` → **`19b67bed8`** (current NEWSLabNTU/nano-ros
`main`). That HEAD carries the 2.C dependencies: Phase 236.B
(`nros::board::ZephyrBoard` + the shared `detail::EntryNodeRuntime`),
Phase 215 board import (`nano_ros_use_board` + `board.cmake` for
`fvp-aemv8r-smp`), and the `nano_ros_entry` cmake + `nros codegen entry
--lang cpp` board-key mapping (`zephyr`/`fvp-aemv8r-smp`/`armfvp` →
`ZephyrBoard`). Verified: `<nros/main.hpp>` defines `class ZephyrBoard`,
`cmake/NanoRosEntry.cmake` defines `nano_ros_entry(...)`, west.yml is
valid YAML, `nros check --workspace`/`--bringup` still pass on the ASI
workspace under the new CLI (0.5.0).

**2.C.1/.2/.3 BLOCKED — stopped per the phase's "report ambiguity, don't
guess" guard (2026-06-11).** The pin bump is the safe, correct, verified
deliverable; the Entry-pkg authoring + `main.cpp` deletion are NOT done
because the `nano_ros_entry` composition with ASI's build is genuinely
ambiguous AND a nano-ros runtime capability is missing. Two distinct
blockers, both rooted in ASI being a **monolithic Zephyr
`project(actuation_module)` build that links 8 autoware component libs
into the Zephyr `app` target** — unlike the simple single-Node native
talker Entry pkgs that `nano_ros_entry` was exercised against:

1. **CMake composition mismatch (resolvable, but unverified + ambiguous).**
   - `nano_ros_entry(...)` calls `add_executable(<NAME>)`. ASI has no
     `add_executable` — `find_package(Zephyr)` owns the bootable `app`
     target and every source is `target_sources(app PRIVATE …)`. The only
     viable Zephyr seam is `nano_ros_entry(NAME app … )` called AFTER
     `find_package(Zephyr)`, relying on the fn's `if(TARGET <NAME>)`
     branch to *append* the generated TU to `app` instead of creating a
     second exe. No in-tree nano-ros example combines
     `nano_ros_use_board` + `nano_ros_entry`; Phase 236.B was verified
     only by `g++ -fsyntax-only` + codegen unit tests, NOT in a real
     Zephyr `app` build (236.C is the open ASI-validation item). So this
     path is plausible but unproven.
   - The codegen emits a link-libs sidecar that does
     `target_link_libraries(<NAME> PRIVATE controller_pkg_controller_component)`
     — a static-lib target that exists ONLY if `controller_pkg` was built
     via `nano_ros_node_register` as its own `project(controller_pkg)`.
     ASI's monolithic build compiles `controller_pkg` as `APP_SOURCES`
     into `app`; there is no `controller_pkg_controller_component` target,
     so `include(<sidecar>)` would fail configure. The
     `controller_pkg.cmake` comment already flags this ("cannot run inside
     the monolithic `project(actuation_module)` build because PROJECT_NAME
     would be `actuation_module`"). Needs a deliberate decision (see
     options).

2. **Runtime capability gap (the hard blocker — needs nano-ros work).**
   The declarative register API on the pinned HEAD
   (`NodeContext::{create_node, create_entity, record_callback_effect}`)
   carries **no executable callback bodies**. `detail::EntryNodeRuntime`
   constructs type-erased pub/sub from descriptor strings and, for a
   timer-`Publishes` binding, *synthesizes a monotonic `std_msgs/Int32`
   counter* — RFC-0032 §8a lists "callback bodies" as an OPEN item and the
   Phase 236 status records "non-Int32 publishers are created live but not
   auto-driven until the callback-body binding lands." ASI's controller is
   the vendored `autoware::…::Controller` (MPC/PID control loop publishing
   `AckermannControlCommand`), whose behaviour lives in C++ subscription /
   timer callbacks wired through the legacy `common/node` shim. The
   generated register sequence calls `__nros_component_controller_pkg_register`,
   whose 2.A body only `create_node`s — it does NOT instantiate the
   vendored `Controller` nor run its control loop, and `EntryNodeRuntime`
   has no way to drive a real C++ callback. **So deleting `main.cpp` +
   `new Controller()` today would boot a controller node that creates
   entities but runs no control logic and publishes nothing meaningful
   (the synthesized Int32 path doesn't even match ASI's message types).**
   This is a nano-ros gap ASI must drive to closure (Phase 236 follow-up:
   callback-body binding for embedded C++ Entry pkgs), exactly the
   reference-consumer role D2 anticipates.

   Because of blocker 2, `main.cpp` was **NOT deleted** — removing the
   working imperative boot before the declarative path can run the
   controller would break ASI's live build with no equivalent. The
   `NROS_WORKSPACE_MODE`-gated `controller_register.cpp` stays gated OFF.

**Options (decide before resuming 2.C):**
- **(A) Wait on nano-ros callback-body binding**, then revisit the CMake
  composition. Cleanest; keeps ASI on the working imperative boot until
  the declarative runtime can actually run the controller. Recommended.
- **(B) Hybrid lift now:** lift `controller_pkg` into its own
  `project(controller_pkg)` + `nano_ros_node_register` static lib so the
  sidecar resolves, have its `register_node` `new` the vendored Controller
  and store it so the existing `common/node`-shim subscriptions/timer run,
  and call `nano_ros_entry(NAME app …)` after `find_package(Zephyr)`. This
  mixes two runtime models (NodeContext arena + legacy shim node) and
  contradicts "controller instantiated by the generated register sequence,
  not `new Controller()`" — a hack, not the declarative target shape.
- **(C) Extend `EntryNodeRuntime`/`NodeContext` upstream** to bind a
  user-supplied C++ callback/instance per node (the real 236-follow-up),
  then ASI authors the Entry pkg cleanly. Largest nano-ros scope; the
  correct long-term design.

- [ ] **2.C.1** Author the Entry pkg: `CMakeLists.txt` with
      `nano_ros_entry(LAUNCH "controller_bringup:system.launch.xml")`
      + `nano_ros_use_board(fvp-aemv8r-smp)`; `src/main.cpp` carries
      `NROS_MAIN(<EmbeddedBoard>, "controller_bringup:system.launch.xml")`.
      **BLOCKED** — see blockers 1 + 2 above. Entry CMake/main.cpp NOT
      authored (would encode an unproven Zephyr-`app` composition and a
      runtime that can't run ASI's controller).
- [ ] **2.C.2** Delete the imperative `actuation_module/src/main.cpp`
      boot (network-wait moves into the Phase 236.B board adapter).
      **NOT DONE** — `main.cpp` retained; deleting it before the
      declarative path can run the control loop (blocker 2) would break
      the live build. Note: `nros_board_network_wait()` IS available as a
      weak hook on the new pin (ASI's `configure_network()` would strong-
      override it) — that part of the design is ready; the boot deletion
      is gated on blocker 2.
- [ ] **2.C.3** `build.sh` drives the Entry pkg build; the
      `--nano-ros-shim` flag retires once the Entry path is the only
      build. **NOT DONE** — deferred with 2.C.1; `build.sh` left untouched
      so the working imperative build keeps running.

**Blocker resolution (2026-06-13) — nano-ros Phase 242 / RFC-0044.** The
2.C rework stopped at a structural entanglement: the vendored Autoware
`Controller` is a **real `rclcpp`-shaped node** (IS-A node; its ctor creates
5 subs / 3 pubs + declares `std::vector<double>` MPC weights; compute is
private), which **RFC-0043's default-construct + `configure(Node&)` component
shape cannot host** (it would default-construct the node + spawn a second
runtime at static-init; the MPC/PID also need a `Node&` + vector params that
`nros::ParameterServer` (scalar-only) can't supply). Decision (2026-06-13):
**make nano-ros rclcpp-faithful** rather than refactor the vendored control
math — nano-ros **RFC-0044** (`nros::ComponentNode`: IS-A node, ctor receives
the executor node handle + wires entities/params, typed member callbacks,
abort-on-fatal) + parameter sequences, tracked by **nano-ros phase-242**. ASI
2.C resumes as **phase-242.5** once that lands: `controller_pkg::Controller`
derives `nros::ComponentNode`, drops the legacy `common/node` shim base, and
its ctor works ~unchanged (no control-math rewrite). The nano-ros-side Zephyr
typed carrier (phase-240.8) already landed; phase-242 is the remaining
dependency. **The pin bump to a 240.8-carrying nano-ros stays; the controller
rework + `main.cpp` deletion wait on phase-242.**

### 2.D — Validation

- [ ] **2.D.1** `nros check` passes on the workspace (identity rule,
      bringup lint, exec_depend drift).
- [ ] **2.D.2** FVP smoke: `controller` publishes
      `/control/trajectory_follower/control_cmd` through the generated
      Entry path, observed by stock `ros2 topic echo` (Phase-1 gate 1.9
      parity, now through workspace mode).

## Acceptance

- [ ] `actuation_module` is a nano-ros workspace: Node pkg + Bringup
      pkg + C++ Entry pkg; no hand-written `main.cpp` boot.
- [ ] Node name + all topics are declarative (launch.xml); zero
      hardcoded names in C++ node code.
- [ ] Board glue is one line — `nano_ros_use_board(fvp-aemv8r-smp)`.
- [ ] FVP runtime parity with Phase 1.

## Notes / cross-refs

- Design + identity-gap analysis: `docs/design/workspace_mode.rst`.
- nano-ros dependencies: Phase 215 (board import), Phase 236 (C++
  embedded Entry runtime) — ASI is the driving consumer of both.
- The `common/node` shim is **not** deleted here; it is *upstreamed* —
  it becomes the nano-ros NodeContext runtime (Phase 236.A/B). ASI
  consumes the upstreamed version.
