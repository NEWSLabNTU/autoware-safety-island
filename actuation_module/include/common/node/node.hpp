#ifndef COMMON__NODE_HPP_
#define COMMON__NODE_HPP_

// nano-ros nros-cpp shim — only build path post-Phase 1.3/1.4 cleanup.
// Legacy raw-Cyclone path lived behind `#ifdef ASI_USE_NANO_ROS` until
// commit history pre-deletion; kept for archaeology in
// `node_nros.hpp` (the active implementation).
#include "common/node/node_nros.hpp"

// Phase 242.5 (RFC-0044) — the controller now derives `nros::ComponentNode`
// (base-swapped off the shim `Node`), and the vendored MPC / PID / VehicleInfoUtils
// take `nros::ComponentNode&` instead of the shim `Node&`. Make the rclcpp-faithful
// node base visible everywhere the shim header is pulled in. The shim `Node` +
// the global `Publisher<M>` alias above stay for the MPC/PID debug-publisher member
// declarations that still reference them (the assignments are disabled).
#include <nros/component_node.hpp>

#endif  // COMMON__NODE_HPP_
