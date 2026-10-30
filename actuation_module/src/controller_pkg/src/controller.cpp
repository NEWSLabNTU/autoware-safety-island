// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 2.C / 242.5 (RFC-0044) — `controller_pkg::Controller` component
// registration TU. Replaces the retired `controller_register.cpp` (the legacy
// `NodeContext`-interpreter register shim, gated OFF behind NROS_WORKSPACE_MODE).
//
// `NROS_COMPONENT(Controller)` emits:
//   * the C-ABI factory `__nros_component_factory_controller_pkg(storage, handle)`
//     that placement-news `controller_pkg::Controller(nros::NodeHandle(handle))`,
//   * the `"controller_pkg::Controller"` class-name marker (lint / identity rule),
//   * the `shape:"rclcpp"` marker (the construct-with-handle IS-A-node shape).
//
// `NROS_PKG_NAME` is injected by `nano_ros_node_register(... CLASS
// controller_pkg::Controller)` as a target compile-definition (= controller_pkg),
// so the macro stamps the markers with the pkg-matching identity. The
// `using namespace` makes the unqualified `Controller` resolve to
// `controller_pkg::Controller` so the stringified marker reads
// `controller_pkg::Controller` (not a doubly-qualified token).

#include "controller_pkg/controller.hpp"

#include <nros/component_node.hpp>

using namespace controller_pkg;  // so NROS_COMPONENT(Controller) names controller_pkg::Controller

NROS_COMPONENT(Controller);
