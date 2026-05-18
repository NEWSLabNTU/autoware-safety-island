# Phase 1B - ASI interface codegen for nano-ros

**Goal.** Generate nano-ros C++ bindings + Cyclone DDS topic descriptors for
ASI's required ROS 2 messages, settle sequence/string capacity rules, and
align type names with stock-RMW wire conventions before touching controller
logic.

**Status.** Draft, not started. **Revised 2026-05-18** — codegen runs from
nano-ros's CMake helpers (`find_package(NanoRos)` +
`find_package(NrosRmwCyclonedds)`). ASI's CMake just calls the helpers.
Generated artifacts stay in the ASI build dir; nothing is checked in.

**Parallelism.** Can run after 1A.1–1A.3 (nano-ros discoverable). Mostly
independent from node adapter work once generated type names + include
paths are agreed.

## Upstream contract

- Typed C++ structs (no DDS-side): `nros_generate_interfaces(<pkg> LANGUAGE
  CPP)` from `find_package(NanoRos)`. Mirrors rosidl semantics; outputs
  `<pkg>.hpp` with `<pkg>::msg::<Type>` over `heapless` / fixed-capacity
  containers.
- Cyclone descriptors (DDS-side): from `find_package(NrosRmwCyclonedds)`:
  - `nros_rmw_cyclonedds_idlc_compile(<out> IDL_FILE <foo.idl> OUTPUT_DIR <d> TYPE_NAME <full::cpp::Type>)`
    per topic type.
  - `nros_rmw_cyclonedds_add_idl_library(<target> IDL_FILES … REGISTER_TYPES …)`
    rolls multiple files into a static lib.
  - Each emits `<stem>_register.c` with `__attribute__((constructor))`
    calling `nros_rmw_cyclonedds_register_descriptor("<pkg>/msg/<Type>",
    &desc)` at static-init (must run before `nros::init`).
- `idlc` invoked with `-t -l c` (skips XTypes type-info section that breaks
  0.10.5; descriptor still valid). Project `LANGUAGES C CXX` required.
- Wire-compat conventions (must match for stock-RMW interop):

  | Surface | Convention |
  |---|---|
  | Pub/sub topic | user `<topic>` → DDS `rt/<topic>` |
  | Service request topic | user `<svc>` → `rq/<svc>Request` |
  | Service reply topic | user `<svc>` → `rr/<svc>Reply` |
  | Message type name | `<pkg>/msg/<T>` → IDL `<pkg>::msg::dds_::<T>_` |
  | Service request type | IDL `<pkg>::srv::dds_::<Svc>_Request_` w/ leading `cdds_request_header_t` |
  | Service reply type | IDL `<pkg>::srv::dds_::<Svc>_Response_` w/ leading `cdds_request_header_t` |

## ASI message source

ASI today owns `.idl` files under
`actuation_module/src/autoware/autoware_msgs/msg/*`. Two paths:

| Path | Pros | Cons |
|---|---|---|
| Downconvert `.idl` → ROS `.msg` | Stock-RMW type names automatic; no nano-ros patches needed | One-time conversion churn; loss of `.idl`-only constructs |
| Feed `.idl` directly | Zero translation | Risk: type names / constants may not survive without nano-ros codegen tweaks |

**Preferred: downconvert.** File any conversion blockers as upstream patches
to nano-ros codegen.

## Work Items

- [ ] **1B.1 - Inventory required interfaces.**
  Start with trajectory, trajectory point, odometry, steering report,
  acceleration, operation mode state, control, lateral, longitudinal, and
  `Float64Stamped`. Flag which carry constants (operation-mode state) and
  which use bounded sequences.
- [ ] **1B.2 - Convert `.idl` → ROS `.msg`/`.srv`.**
  Land conversion tooling (script or one-time edit). Preserve ROS package
  names: `autoware_planning_msgs`, `autoware_control_msgs`,
  `geometry_msgs`, `nav_msgs`, `tier4_debug_msgs`.
- [ ] **1B.3 - Confirm package/type mapping.**
  Verify `<pkg>::msg::dds_::<T>_` IDL names match generated Cyclone
  descriptors and stock `rmw_cyclonedds_cpp` expectations.
- [ ] **1B.4 - Set sequence capacities.**
  Define fixed capacities for trajectory points + arrays. Baseline:
  `TrajectoryMsg` reserves 250 points. Document the chosen values + the
  CMake mechanism for setting them.
- [ ] **1B.5 - Wire C++ binding generation in ASI build.**
  Add `find_package(NanoRos)` + per-package `nros_generate_interfaces(...
  LANGUAGE CPP)` to ASI CMake. Outputs land in build dir. Not committed.
- [ ] **1B.6 - Wire Cyclone descriptor generation.**
  Add `find_package(NrosRmwCyclonedds)` + `nros_rmw_cyclonedds_add_idl_library`
  for the ASI message set. Link the static lib into the actuation module so
  `__attribute__((constructor))` registrations fire before `nros::init`.
- [ ] **1B.7 - Add narrow conversion helpers if needed.**
  Provide helpers between generated nros-cpp messages and existing
  controller aliases (e.g. `TrajectoryMsg` ↔
  `autoware_planning_msgs::msg::Trajectory`) when direct replacement would
  ripple into MPC / PID / CAN. Goal: keep algorithm files unchanged.
- [ ] **1B.8 - File upstream gaps as nano-ros patches.**
  Likely candidates: per-package bounded-sequence capacity knob, direct
  IDL ingestion option, descriptor-registration ordering vs `nros::init`
  on Zephyr. Patches land in `~/repos/nano-ros-autoware`.

## Acceptance Criteria

- [ ] Generated C++ headers compile under ASI's Zephyr C++14 settings.
- [ ] Constants used by operation-mode code available in generated form.
- [ ] `Trajectory` carries at least 250 points or fails loudly when larger.
- [ ] Generated Cyclone descriptors register successfully; `find_package`
      consumers link without manual `extern "C"` plumbing.
- [ ] IDL type names round-trip to stock `rmw_cyclonedds_cpp` (verified
      in Phase 1E E2E).
- [ ] No controller algorithm files need broad rewrites for message
      plumbing.
- [ ] No generated files committed in ASI.

## Likely Files

- `actuation_module/src/autoware/autoware_msgs/msg/*` (`.idl` → `.msg`)
- `actuation_module/src/autoware/autoware_msgs/include/autoware/autoware_msgs/messages.hpp`
- `actuation_module/src/autoware/autoware_msgs/CMakeLists.txt`
- `actuation_module/CMakeLists.txt` (codegen wiring)
- `~/repos/nano-ros-autoware/packages/dds/nros-rmw-cyclonedds/cmake/NrosRmwCycloneddsTypeSupport.cmake` (reference)
- `~/repos/nano-ros-autoware/packages/codegen/interfaces/*` (reference)
