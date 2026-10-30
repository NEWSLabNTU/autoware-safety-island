#ifndef COMMON__NODE_HPP_
#define COMMON__NODE_HPP_

// Phase 5 W3 — nros-only node header: thin aliases over nros-cpp
// (`nros::ComponentNode`). The legacy raw-CycloneDDS node base retired with
// the freertos-s32z2-legacy lane.

// Phase 5 W5 — the polling shim (`node_nros.hpp`) is GONE: the controller
// derives `nros::ComponentNode` (Phase 242.5 / RFC-0044) and the test
// programs were ported to it too. nros mode is a thin alias layer over
// nros-cpp.
#include <memory>

#include <nros/component_node.hpp>
#include <nros/nros.hpp>

// Phase 3 W1 — the node-argument type the vendored autoware components take
// (`AsiNode &`). nros mode: the rclcpp-faithful ComponentNode base.
using AsiNode = nros::ComponentNode;

// MPC/PID debug-publisher member declarations reference a global
// `Publisher<M>` (assignments disabled — see mpc.hpp). Alias it to the
// nros-cpp publisher now that the shim wrapper is gone.
template <typename M>
using Publisher = nros::Publisher<M>;



#endif  // COMMON__NODE_HPP_
