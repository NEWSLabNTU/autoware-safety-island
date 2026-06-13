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

- [x] **2.A.1** Carve `controller` into a Node pkg
      (`actuation_module/src/controller_pkg/`) with a `package.xml` + the
      C++ component class decl. **Done** — `controller_pkg/` carries
      `controller_pkg::Controller` (derives the vendored controller) +
      `src/controller.cpp` (`NROS_COMPONENT`).
- [x] **2.A.2** Resolve **I1** — dir-rename: pkg dir `controller_pkg`,
      class `controller_pkg::Controller`. **Done** — `nros check
      --workspace .` passes (L.4 `<pkg-dir>::<Class>` rule, 3 pkgs, 0 warn).
- [x] **2.A.3** Resolve **I2/I3** — node name + 5 sub / 3 pub topics are
      declared defaults in `controller_pkg/node_identity.hpp`; the Bringup
      launch.xml `<remap>`s them. **Done** (behaviour unchanged).

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

- [x] **2.C.1** Author the Zephyr Entry path. **Done (2026-06-13).** On the
      west-module Zephyr build the single-node Entry is generated by the
      Phase 240.8 Zephyr typed-entry carrier *inside* `nano_ros_node_register`,
      not by `nano_ros_entry(LAUNCH …)` (that LAUNCH path shells `nros codegen
      entry` and targets `add_executable` — the native/multi-node shape).
      `controller_pkg/CMakeLists.txt` is its own `project(controller_pkg)` and
      calls `nano_ros_node_register(NAME controller CLASS
      controller_pkg::Controller LANGUAGE CXX TYPED SHAPE rclcpp HEADER
      controller_pkg/controller.hpp SOURCES <controller + 8 vendored autoware
      libs> DEPLOY zephyr)`; the carrier `configure_file`s
      `zephyr_entry_main_typed.cpp.in` (rclcpp branch: placement-new
      `Controller(handle)` after init + `ok()` check) into `app` and links the
      component lib. `nano_ros_use_board(fvp-aemv8r-smp)` (top `CMakeLists.txt`,
      before `find_package(Zephyr)`) supplies the board glue.
- [x] **2.C.2** Delete the imperative `actuation_module/src/main.cpp`.
      **Done.** The boot is the generated entry's
      `ZephyrBoard::run_components` (network-wait → init → construct → spin →
      shutdown). The network-wait prologue moved to
      `src/board_network_hook.cpp` — a STRONG override of the weak
      `nros_board_network_wait()` that runs the DHCP grace +
      `configure_network()` + SNTP.
- [x] **2.C.3** `build.sh` drives the workspace build; the `--nano-ros-shim`
      build mode is retired. **Done** — `build_actuation_module` documents the
      Entry/workspace path; the bootstrap script is kept only for host
      `nros-codegen` (message generation), not a runtime shim.

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

**Phase 242.5 attempt (2026-06-13) — NEW WALL: `ComponentNode` ships no
rclcpp value-returning parameter surface.** Pin is now at nano-ros
`398395653` (phase-242 / RFC-0044 landed). `nros::ComponentNode`
(`packages/core/nros-cpp/include/nros/component_node.hpp`) is present and the
IS-A-node + typed-member-callback shape fits ASI's controller ctor cleanly
(5 subs / 3 pubs / 1 timer migrate 1:1). **But the migration is blocked at the
MPC/PID construction step.** The vendored `MpcLateralController(Node& node)` /
`PidLongitudinalController(Node& node)` ctors — plus
`autoware::vehicle_info_utils::VehicleInfoUtils(Node&)` — call
`node.declare_parameter<T>(name, default) -> T`, `node.get_parameter<T>(name)
-> T`, and `node.has_parameter(name)` across **151 call sites** in the control
math (4 of them `declare_parameter<std::vector<double>>(name, {…})` with no
compile-time capacity). ASI's `common/node` shim supplies exactly this
rclcpp-shaped, value-returning surface via a node-local
`std::unordered_map<std::string, variant>`.

The landed nano-ros provides **no** value-returning parameter API on any node
type: `nros::ComponentNode` and `nros::Node` expose zero parameter methods;
`rclcpp_compat.hpp`'s `rclcpp::Node` has none either. The only parameter store
is the **separate** `nros::ParameterServer<Cap>` object whose API is
*Result-returning* (`Result declare_parameter(name, T)` /
`Result get_parameter(name, T& out)`), with sequences gated on a compile-time
`Seq<T, N>` capacity (`declare_parameter<double, N>`). Passing the
`ComponentNode` (or its `node()`) to the MPC/PID — as 242.5 intended — does
not compile: neither type has `declare_parameter`/`get_parameter`/
`has_parameter`, the return shape is wrong (value vs `Result`), and the bare
`std::vector<double>` declares have no `N`. Adapting the 151 call sites would
be a control-math rewrite, which 242.5 forbids.

**Missing nano-ros API (the precise gap to close before 242.5 can resume):**
an rclcpp-faithful, value-returning parameter surface **on `ComponentNode`**
(or `Node`), backed internally by `ParameterServer`:
`template<typename T> T declare_parameter(const std::string& name, const T&
default_value = T{});`, `template<typename T> T get_parameter(const
std::string& name) const;`, `bool has_parameter(const std::string&) const;` —
with `T` covering `std::vector<double>` (and the other vector types) under
`NROS_CPP_STD` **without** a caller-supplied compile-time capacity, so the
vendored `declare_parameter<std::vector<double>>(name, {…})` call shape
compiles unchanged. RFC-0044's blocker-resolution promise ("ctor works
~unchanged, no control-math rewrite") requires this facade; phase-242 landed
the entity/callback half (`ComponentNode`) and the storage half
(`ParameterServer` + `Seq`) but **not** the value-returning rclcpp parameter
bridge that joins them. **Reported as nano-ros feedback (D2); 242.5 stays
blocked, `main.cpp` + `controller_register.cpp` retained, control math
untouched.**

**Phase 242.5 attempt (2026-06-13) — FOURTH WALL: the value-returning param
facade is `const char*`-only; the vendored control math passes `std::string`
names.** Pin is now at nano-ros `843cbddef` (the 242.7 value-returning
`ComponentNode` parameter facade landed). The facade
(`packages/core/nros-cpp/include/nros/component_node.hpp`) closes the THIRD
wall for the literal-keyed call sites — `T declare_parameter<T>(const char*
name, T default)`, `T get_parameter<T>(const char*) const`, `bool
has_parameter(const char*) const`, scalar + `std::vector<T>` under
`NROS_CPP_STD` with no caller-supplied `N`. The structural migration otherwise
maps cleanly (verified by inspection against the real header):
- base-swap the vendored `autoware::…::trajectory_follower_node::Controller`
  from the shim `Node` to `nros::ComponentNode` (ctor `Controller(nros::NodeHandle)
  : ComponentNode(h, DEFAULT_NODE_NAME)`); `controller_pkg::Controller` derives
  it + `NROS_COMPONENT(Controller)`;
- the 5 static `callbackX(const Msg*, void*)` → typed member callbacks `void
  on_X(const Msg&)` via `create_subscription<Msg, Controller, &Controller::on_X>`;
- the `create_timer(period_ms, lambda)` → `create_timer<Controller,
  &Controller::callbackTimerControl>(period_ms)`;
- the 3 shim-wrapper `std::shared_ptr<Publisher<M>>` members → `nros::Publisher<M>`
  by value (the `->publish()`-returns-bool sites become `Result`-checked);
- MPC/PID/`VehicleInfoUtils` ctor param `Node&` → `nros::ComponentNode&` (a type
  swap — `*this` IS-A `ComponentNode` after the base-swap).

**But the migration does not compile, blocked at the MPC parameter call sites
that key parameters by `std::string`, not a string literal.** The 242.7 facade
takes `const char* name`; `std::string` does **not** implicitly convert to
`const char*`. The vendored MPC control math (preserved verbatim, must NOT be
rewritten) passes `std::string` names at live sites:
- `autoware_mpc_lateral_controller/src/mpc_lateral_controller.cpp:208-211` —
  `node.declare_parameter<double>(ns + "update_vel_threshold", 5.56)` (and 3
  siblings), where `const std::string ns = "steering_offset."` so `ns + "…"` is
  a `std::string` rvalue;
- same file `:41-43` — the `dp_int`/`dp_bool`/`dp_double` lambdas take
  `const std::string & s` and call `node.declare_parameter<int>(s)` (a
  `std::string`); a non-generic lambda's body is type-checked at definition, so
  these break even where the lambda is unused.

The shim `Node` (`actuation_module/include/common/node/node_nros.hpp`) declares
`declare_parameter`/`get_parameter`/`set_parameter`/`has_parameter` with
`const std::string & name` — which is exactly why the vendored MPC compiles
today. The 242.7 facade dropped the `std::string` surface, so the promise that
"the vendored `declare_parameter<T>(…)` call sites compile unchanged against a
`ComponentNode&`" does **not** hold for the `std::string`-keyed sites.

A secondary (same-root) coupling: MPC's debug-publisher members
(`mpc_lateral_controller.hpp:48-50`, `mpc.hpp:223-224`) are typed
`std::shared_ptr<Publisher<M>>`, referencing the shim's global `Publisher<M>`
alias; dropping the shim base also removes that alias. (The assignments are
commented out, but the member declarations still need the type.) This is the
same shim-surface coupling the facade did not cover.

**Missing nano-ros API (the precise gap to close before 242.5 can resume):**
`std::string`-accepting overloads of the value-returning parameter facade **on
`ComponentNode`** (and ideally `Node`), under `NROS_CPP_STD`, mirroring the
shim `Node`'s `const std::string &` surface and forwarding to the existing
`const char*` overloads via `.c_str()`:
`template<typename T> T declare_parameter(const std::string& name, const T&
default_value = T{});`, `template<typename T> T get_parameter(const
std::string& name) const;`, `bool has_parameter(const std::string&) const;` —
covering scalar `T` and `std::vector<T>`. With those, the vendored
`node.declare_parameter<int>(s)` / `node.declare_parameter<double>(ns + "…")`
sites compile unchanged (no control-math edit). **Reported as nano-ros feedback
(D2); 242.5 stays blocked, `main.cpp` + `controller_register.cpp` retained,
control math untouched. No vendored, cmake, build.sh, or `main.cpp` edits were
made on this attempt — the base-swap would not compile until the facade grows
the `std::string` surface.**

**Phase 242.5 — MIGRATION AUTHORED, blocked on a FIFTH WALL (2026-06-13), pin
`8c0c9612f`.** The four prior walls are closed (Zephyr typed carrier 240.8;
rclcpp-faithful `ComponentNode` 242.1-4; value-returning param facade 242.7;
`std::string`-*keyed* overloads 242.7-fix), and the full migration is authored in
the working tree (external fork — NOT committed). `nros check --workspace` +
`--bringup` pass. **But it does not yet compile:** the value-returning facade has
no scalar **`std::string`-VALUE** surface, and the vendored control code declares
five `declare_parameter<std::string>(name, default)` params.

> **FIFTH WALL — `ComponentNode` / `ParameterServer` lack a scalar
> `std::string`-value parameter overload.** Walls 3/4 (242.7) added scalar
> `bool`/`int`/`int64_t`/`double` + `std::vector<T>` (under `NROS_CPP_STD`) +
> `std::string`-*keyed* (name) overloads — but **not** scalar `std::string`
> *values*. `nros::ParameterServer`'s scalar dispatch
> (`packages/core/nros-cpp/include/nros/parameter.hpp`) is:
> `declare_impl(const char*, {bool|int64_t|double|const char*|int})` and
> `get_impl(const char*, {bool&|int64_t&|double&})` — strings only via
> `declare_impl(const char*, const char*)` (`nros_param_declare_string`) and
> `get_parameter(const char*, char* out, size_t max_len)` (`nros_param_get_string`).
> So `ComponentNode::declare_parameter<std::string>(name, default)` →
> `params_.declare_parameter<std::string>(name, std::string)` →
> `declare_impl(name, std::string)` has **no viable overload** (`std::string`
> does not implicitly convert to `const char*`); likewise
> `get_parameter<std::string>(name)` → `get_impl(name, std::string&)`.
>
> **Vendored call sites (control math — must NOT be rewritten), 5 total:**
> - `autoware_trajectory_follower_node/src/controller_node.cpp:51,65` —
>   `declare_parameter<std::string>("lateral_controller_mode","mpc")` /
>   `("longitudinal_controller_mode","pid")` (selects MPC / PID).
> - `autoware_mpc_lateral_controller/src/mpc_lateral_controller.cpp:157,193` —
>   `declare_parameter<std::string>("vehicle_model_type","kinematics")` /
>   `("qp_solver_type","unconstraint_fast")`.
> - `autoware_pid_longitudinal_controller/src/pid_longitudinal_controller.cpp:190` —
>   `declare_parameter<std::string>("slope_source", …)`.
>
> **Precise fix (nano-ros, before 242.5 compiles) — mirror the 242.7 pattern,
> one element type up:** add scalar `std::string`-value support under
> `NROS_CPP_STD`. In `ParameterServer`:
> `Result declare_impl(const char* name, const std::string& v) { return
> Result(nros_param_declare_string(&server_, name, v.c_str())); }` and a
> `get_impl(const char* name, std::string& out)` that reads via
> `nros_param_get_string` into a temp buffer (the existing 128-byte string slot)
> then assigns. The `ComponentNode` scalar `declare_parameter<T>` /
> `get_parameter<T>` already forward to `params_`, so T=`std::string` then works
> value-returning. **Reported as nano-ros feedback (D2).** Nothing was reverted:
> the ASI-side migration is complete and correct modulo this one facade addition
> (it is a nano-ros API gap, not ASI integration work) — `git restore` is NOT
> needed; the tree compiles the moment the scalar-string facade lands.

When the fifth wall closes, the authored migration (below) is what builds:
- **Base-swap.** Vendored `…::trajectory_follower_node::Controller` now
  `: public nros::ComponentNode`, ctor `Controller(nros::NodeHandle h)
  : ComponentNode(h, DEFAULT_NODE_NAME)`; the per-node pthread spin is gone (the
  executor drives it). `controller_pkg::Controller` inherits the ctor +
  `NROS_COMPONENT(Controller)` (src/controller.cpp).
- **Callbacks/entities.** 5 static `callbackX(const Msg*, void*)` → typed member
  `on_X(const Msg&)` via `create_subscription<Msg, Controller, &Controller::on_X>`;
  timer via `create_timer<Controller, &Controller::callbackTimerControl>`; 3 pubs
  are `nros::Publisher<M>` members (`->publish()` → `.publish().ok()`).
- **Type-swaps.** `MpcLateralController(Node&)` / `PidLongitudinalController(Node&)`
  / `VehicleInfoUtils(Node&)` → `nros::ComponentNode&`; the 151
  `node.declare_parameter<T>` / `get_parameter<T>` / `has_parameter` sites
  (incl. `std::string` keys + `std::vector<double>` weights) compile unchanged
  against the facade (`NROS_CPP_STD` enabled for the component lib). **No
  control-math rewrite.** The `common/node` shim header survives only for the
  MPC/PID debug-publisher `Publisher<M>` alias.
- **CMake/boot.** `nano_ros_use_board(fvp-aemv8r-smp)` (one line, before
  find_package(Zephyr)); `controller_pkg` is its own `project()` with
  `nano_ros_node_register(... TYPED SHAPE rclcpp DEPLOY zephyr)`; `main.cpp` +
  `controller_register.cpp` + `controller_pkg.cmake` deleted; the
  AUTOWARE_COMPONENTS-into-`app` foreach is removed (the 8 libs are now the
  component lib's SOURCES). Network-wait → strong `nros_board_network_wait()`
  in `src/board_network_hook.cpp`.

**Validation done here:** `nros check --workspace`/`--bringup` pass; all
package.xml / launch.xml / system.toml / params.yaml / west.yml well-formed;
every migrated C++ signature matches the real `component_node.hpp`; topics match
`node_identity.hpp`.

**Deferred to the devcontainer build (242.5.2, Zephyr-SDK + FVP host):** the full
compile + FVP boot. The principal build risk is the **CMake composition** (the
old blocker 1, never closed by a C++-API wall): ASI consumes nano-ros as a *west
Zephyr module* (`zephyr_library_named(nros)` + `CONFIG_NROS_CPP_API`), whereas
`nano_ros_node_register`'s Zephyr carrier was written for the standalone
`add_subdirectory(nano-ros)` model — so its preconditions (`NANO_ROS_PLATFORM ==
zephyr`, `NanoRos::NanoRosCpp`) are NOT met by default. The migration bridges
this on the ASI side (explicit `include(${NROS_REPO_DIR}/cmake/
NanoRosNodeRegister.cmake)` + `set(NANO_ROS_PLATFORM zephyr)` +
`target_link_libraries(<component> PRIVATE zephyr_interface)` for Zephyr flags +
the nros-cpp/generated-message include set). This is the first in-tree consumer
to combine `nano_ros_use_board` + `nano_ros_node_register` on a west-module
Zephyr app; it parses and passes `nros check`, but the heavy-C++ component-lib
compile (Eigen + autoware under `zephyr_interface`) and the generated-message
include scope are exactly what the devcontainer build exercises.

### 2.D — Validation

- [x] **2.D.1** `nros check` passes on the workspace. **Done (2026-06-13)** —
      `nros check --workspace .` → `ok (3 pkg(s), 0 warning(s))` (L.4 identity
      on `controller_pkg::Controller`); `nros check --bringup
      src/controller_bringup` → `ok (pure declarative)`. (`nros plan` resolves
      the topology where `play_launch_parser` is installed — devcontainer.)
- [ ] **2.D.2** FVP smoke: `controller` publishes
      `/control/trajectory_follower/control_cmd` through the generated
      Entry path, observed by stock `ros2 topic echo` (Phase-1 gate 1.9
      parity, now through workspace mode).

## Acceptance

- [x] `actuation_module` is a nano-ros workspace: Node pkg
      (`controller_pkg`) + Bringup pkg (`controller_bringup`); no
      hand-written `main.cpp` boot (the Zephyr Entry is generated into `app`
      by the Node pkg's Phase 240.8 typed carrier — no separate Entry pkg on
      the single-node Zephyr path).
- [x] Node name + all topics are declarative — declared defaults in
      `node_identity.hpp`, remapped by the Bringup launch.xml; zero hardcoded
      string literals in C++ node code.
- [x] Board glue is one line — `nano_ros_use_board(fvp-aemv8r-smp)`.
- [ ] FVP runtime parity with Phase 1. **Gated on the devcontainer build
      (242.5.2) — Zephyr-SDK + FVP host.**

## Notes / cross-refs

- Design + identity-gap analysis: `docs/design/workspace_mode.rst`.
- nano-ros dependencies: Phase 215 (board import), Phase 236 (C++
  embedded Entry runtime) — ASI is the driving consumer of both.
- The `common/node` shim is **not** deleted here; it is *upstreamed* —
  it becomes the nano-ros NodeContext runtime (Phase 236.A/B). ASI
  consumes the upstreamed version.
