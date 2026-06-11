// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 2.A — single declared-defaults source for the `controller` node.
//
// This header is the ONE place ASI's controller node identity lives:
//
//   * I2 (node name) — `DEFAULT_NODE_NAME` replaces the `"controller"`
//     literal that used to be baked into the vendored
//     `Controller::Controller() : Node("controller", …)` ctor.
//   * I3 (topics)   — the 5 subscription + 3 publisher topic strings
//     that used to be scattered as inline literals across the vendored
//     `create_subscription` / `create_publisher` call sites are
//     collected here as the node's *declared defaults*.
//
// Phase 2.B layers a Bringup pkg `launch.xml` on top: `<node name=…>`
// overrides `DEFAULT_NODE_NAME` and `<remap from=<default> to=…>`
// rewrites the topics. The strings below stay as the declared defaults
// so behaviour is unchanged until a launch file remaps them — they are
// the `from=` side of every future remap.
//
// Keep this header free of any nano-ros runtime include so it can be
// pulled into both the vendored controller TU (legacy-shim build) and
// the Phase 2.C component node-decl (`controller_register.cpp`) without
// dragging in headers that differ between the two build paths.

#ifndef CONTROLLER_PKG__NODE_IDENTITY_HPP_
#define CONTROLLER_PKG__NODE_IDENTITY_HPP_

namespace controller_pkg {
namespace node_identity {

// I2 — the node's declared default name. A Bringup pkg `<node name=…>`
// (Phase 2.B) overrides this; until then it is the single source of the
// name that used to be the `"controller"` ctor literal.
inline constexpr const char* DEFAULT_NODE_NAME = "controller";

// I3 — declared-default topics. Subscriptions the controller consumes.
namespace topics {

// --- Subscriptions (5) ---
inline constexpr const char* SUB_STEERING_STATUS =
    "/vehicle/status/steering_status";
inline constexpr const char* SUB_TRAJECTORY =
    "/planning/scenario_planning/trajectory";
inline constexpr const char* SUB_ODOMETRY =
    "/localization/kinematic_state";
inline constexpr const char* SUB_ACCELERATION =
    "/localization/acceleration";
inline constexpr const char* SUB_OPERATION_MODE_STATE =
    "/system/operation_mode/state";

// --- Publishers (3) ---
inline constexpr const char* PUB_CONTROL_CMD =
    "/control/trajectory_follower/control_cmd";
inline constexpr const char* PUB_PROCESSING_TIME_LAT_MS =
    "/control/trajectory_follower/lateral/debug/processing_time_ms";
inline constexpr const char* PUB_PROCESSING_TIME_LON_MS =
    "/control/trajectory_follower/longitudinal/debug/processing_time_ms";

}  // namespace topics
}  // namespace node_identity
}  // namespace controller_pkg

#endif  // CONTROLLER_PKG__NODE_IDENTITY_HPP_
