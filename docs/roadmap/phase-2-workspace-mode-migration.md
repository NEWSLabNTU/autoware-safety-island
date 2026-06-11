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

- [ ] **2.C.1** Author the Entry pkg: `CMakeLists.txt` with
      `nano_ros_entry(LAUNCH "controller_bringup:system.launch.xml")`
      + `nano_ros_use_board(fvp-aemv8r-smp)`; `src/main.cpp` carries
      `NROS_MAIN(<EmbeddedBoard>, "controller_bringup:system.launch.xml")`.
- [ ] **2.C.2** Delete the imperative `actuation_module/src/main.cpp`
      boot (network-wait moves into the Phase 236.B board adapter).
- [ ] **2.C.3** `build.sh` drives the Entry pkg build; the
      `--nano-ros-shim` flag retires once the Entry path is the only
      build.

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
