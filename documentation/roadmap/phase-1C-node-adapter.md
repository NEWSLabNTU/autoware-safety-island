# Phase 1C - delete `common/dds`, replace `common/node` with nros-cpp shim

**Goal.** Remove ASI's raw Cyclone wrapper (`common/dds/*`) and rework
`common/node/*` as a thin shim over `nros::Node` / `nros::Publisher<M>` /
`nros::Subscription<M>`. Keep `controller_node.cpp` and Autoware algorithm
code unchanged except for trivial signature edits (drop explicit Cyclone
descriptor args).

**Status.** Draft, not started. **Revised 2026-05-18** — architecture pivot:
nano-ros is the sole RMW. `common/dds` is deleted, not refactored.
`common/node` shrinks to an API-shape preservation layer; optional final
follow-up deletes it entirely once controllers move to `nros::Node`
directly.

**Parallelism.** Can run beside 1B after temporary message types chosen.
Final integration waits for 1B generated interfaces.

## Current ASI API surface (`controller_node.cpp`)

```cpp
class Controller : public Node {
  Controller() : Node("controller", node_stack, STACK_SIZE) {
    const double ctrl_period = declare_parameter<double>("ctrl_period", 0.15);
    create_timer(period_ms, [this]() { callbackTimerControl(); });
    auto sub = create_subscription<SteeringReportMsg>(
        "/vehicle/status/steering_status",
        &autoware_vehicle_msgs_msg_SteeringReport_desc, cb, this);
    control_cmd_pub_ = create_publisher<ControlMsg>(
        "/control/trajectory_follower/control_cmd",
        &autoware_control_msgs_msg_Control_desc);
    control_cmd_pub_->publish(out);
  }
};
```

Notice: `create_subscription` / `create_publisher` take an explicit Cyclone
**descriptor** pointer. nros-cpp hides descriptor lookup behind the
generated message type (`nros::Publisher<M>`).

## Target API after shim

```cpp
class Controller : public Node {
  Controller() : Node("controller") {
    const double ctrl_period = declare_parameter<double>("ctrl_period", 0.15);
    create_timer(period_ms, [this]() { callbackTimerControl(); });
    auto sub = create_subscription<SteeringReportMsg>(
        "/vehicle/status/steering_status", cb, this);
    control_cmd_pub_ = create_publisher<ControlMsg>(
        "/control/trajectory_follower/control_cmd");
    control_cmd_pub_->publish(out);
  }
};
```

Diff: descriptor arg goes away. Constructor stack-size args go away
(`nros::Node` storage is compile-time-asserted via Phase 87/118 size probe).
Everything else stays.

## Adapter mapping

| ASI shim surface | nros-cpp target |
|---|---|
| `Node` ctor | `nros::Node` + `nros::create_node` (called from shim ctor) |
| `declare_parameter<T>` | `nros::Node::declare_parameter<T>` |
| `create_publisher<M>(topic)` | wraps `nros::Publisher<M>` + `node.create_publisher(...)` |
| `create_subscription<M>(topic, cb, arg)` | wraps `nros::Subscription<M>` with cb adapter |
| `create_timer(period, cb)` | application-driven polling (today) or `nros::Executor::spin(period)` |
| `Publisher<T>::publish(msg)` | `nros::Publisher<M>::publish` |
| spin / lifetime | `nros::init` / `nros::shutdown` from `main.cpp` |

## Work Items

- [ ] **1C.1 - Delete `common/dds`.**
  Remove `actuation_module/include/common/dds/*` and
  `actuation_module/src/common/dds/*`. Drop matching includes. CMake target
  cleanup.
- [ ] **1C.2 - Rewrite `common/node` as nros-cpp shim.**
  Keep public surface (`Node`, `Publisher<T>`, `create_subscription`,
  `create_publisher`, `declare_parameter`, `create_timer`). Internals
  hold a `nros::Node` and forward calls. Drop the descriptor parameter
  from the public API.
- [ ] **1C.3 - Preserve parameter behavior.**
  Map `declare_parameter<T>` onto `nros::Node::declare_parameter<T>`.
  Verify variant types (bool/i64/f64/string) cover current MPC / PID /
  controller defaults.
- [ ] **1C.4 - Preserve timer behavior.**
  Keep the 150 ms control timer driving from application code.
  Optionally evaluate `nros::Executor::spin(duration_ms)` (wall-clock
  budgeted spin landed in Phase 118.C.b).
- [ ] **1C.5 - Add lifecycle ownership.**
  Decide where `nros::init`, node creation, spin, and `nros::shutdown`
  live in ASI `main.cpp`. Choose whether
  `NROS_APP_MAIN_REGISTER_ZEPHYR()` replaces or wraps ASI's current
  `main`.
- [ ] **1C.6 - Port `controller_node.cpp` call sites.**
  Drop descriptor args from `create_subscription` / `create_publisher`
  calls. Update generated-type includes (e.g.
  `autoware_vehicle_msgs_msg_SteeringReport_desc` → typed
  `autoware_vehicle_msgs::msg::SteeringReport`).
- [ ] **1C.7 - Adopt nros-cpp error-handling idioms.**
  Use `NROS_TRY_RET` at shim seams. Expose `nros::Result` raw codes via
  ASI logger so existing log lines stay actionable.
- [ ] **1C.8 - Keep legacy path selectable during migration (optional).**
  If parallel comparison is needed, gate the shim behind
  `ASI_USE_NANO_ROS=ON` and keep the raw Cyclone path under
  `ASI_USE_NANO_ROS=OFF` until tests are green. Error if both paths try
  to own the same topic in one build.
- [ ] **1C.9 - Plan shim deletion (deferred).**
  Track a follow-up to delete `common/node` entirely and move controllers
  to `nros::Node` directly once the shim has no shape-preservation
  benefit.

## Acceptance Criteria

- [ ] `actuation_module/include/common/dds/` and
      `actuation_module/src/common/dds/` removed from tree.
- [ ] `common/node` exposes the historical public surface (minus
      descriptor args) and forwards to `nros-cpp`.
- [ ] Controller constructor changes are mechanical and small.
- [ ] `processData()`, MPC, PID, and CAN output logic remain
      behaviorally unchanged.
- [ ] Shim compiles with generated ASI message types from Phase 1B.
- [ ] `nros::init` failure surfaces a clear log line and a non-zero exit
      from `main` / `nros_app_main`.

## Likely Files

- `actuation_module/include/common/node/node.hpp`
- `actuation_module/include/common/node/timer.hpp`
- `actuation_module/include/common/dds/*` (delete)
- `actuation_module/src/common/dds/*` (delete)
- `actuation_module/src/autoware/autoware_trajectory_follower_node/src/controller_node.cpp`
- `actuation_module/src/main.cpp`
- `~/repos/nano-ros-autoware/packages/core/nros-cpp/include/nros/nros.hpp` (reference)
