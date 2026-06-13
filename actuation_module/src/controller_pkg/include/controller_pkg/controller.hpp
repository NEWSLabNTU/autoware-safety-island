// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 2.A — `controller_pkg::Controller`, the nano-ros Node pkg class.
//
// I1 (identity rule). nano-ros's `nros check` enforces
// `class == <pkg-dir>::<UserClass>` (the cmake fn `nano_ros_node_register`
// rejects a CLASS that does not start with the pkg name; the C++
// `NROS_NODE(UserClass)` macro stamps the marker
// `"<NROS_PKG_NAME>::<UserClass>"`). ASI's controller violated this: its
// pkg dir is `autoware_trajectory_follower_node` while its class is
// `autoware::motion::control::trajectory_follower_node::Controller` —
// neither the dir nor the namespace agree.
//
// The user decided I1 = **dir-rename** (not the alias-shim that would
// re-register the vendored class under a pkg-matching alias string in
// place). We realise the dir-rename surgically: a NEW Node pkg directory
// `controller_pkg/` whose canonical class is `controller_pkg::Controller`.
// The pkg dir and the registered class now agree:
//
//     pkg dir  = controller_pkg
//     class    = controller_pkg::Controller   ✓  (<pkg-dir>::Controller)
//
// The vendored `autoware_trajectory_follower_node` tree is preserved
// verbatim (logic untouched) and demoted from "the node" to a plain
// implementation library — consistent with roadmap gap I4 (the autoware
// components are libs, not nodes). `controller_pkg::Controller` derives
// from the vendored controller so it IS a real, distinct type (not a
// `using` alias), carrying ASI's node identity. `main.cpp` instantiates
// THIS class.

#ifndef CONTROLLER_PKG__CONTROLLER_HPP_
#define CONTROLLER_PKG__CONTROLLER_HPP_

#include "autoware/trajectory_follower_node/controller_node.hpp"
#include "controller_pkg/node_identity.hpp"

namespace controller_pkg {

/// \brief ASI's trajectory-follower control node.
///
/// Wraps (derives from) the vendored autoware controller so the pkg
/// directory (`controller_pkg`) and the registered class name
/// (`controller_pkg::Controller`) satisfy nano-ros's identity rule
/// without editing the vendored implementation's logic. All controller
/// behaviour — the 5 subscriptions, 3 publishers, timer, MPC + PID
/// controllers — comes from the base class; the node name and topic
/// strings are sourced from `controller_pkg/node_identity.hpp`.
/// Phase 242.5 (RFC-0044). The vendored base is now `nros::ComponentNode` (an
/// IS-A-node, construct-with-handle component). `controller_pkg::Controller`
/// inherits the base's `explicit Controller(nros::NodeHandle)` ctor so the
/// generated Zephyr Entry carrier can placement-new it with the executor handle.
/// The pkg dir (`controller_pkg`) and registered class (`controller_pkg::Controller`)
/// satisfy nano-ros's `<pkg-dir>::<UserClass>` identity rule. `NROS_COMPONENT`
/// registration + the rclcpp shape marker live in `src/controller.cpp`.
class Controller final
    : public ::autoware::motion::control::trajectory_follower_node::Controller {
  public:
    using ::autoware::motion::control::trajectory_follower_node::Controller::Controller;
};

}  // namespace controller_pkg

#endif  // CONTROLLER_PKG__CONTROLLER_HPP_
