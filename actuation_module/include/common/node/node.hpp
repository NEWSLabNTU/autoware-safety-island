#ifndef COMMON__NODE_HPP_
#define COMMON__NODE_HPP_

// Phase 5 W3 - nros-only node header: thin aliases over nros-cpp's rclcpp
// API. The legacy raw-CycloneDDS node base retired with the
// freertos-s32z2-legacy lane.
//
// The controller derives `rclcpp::NodeWithTimers<1>` (nano-ros phase-427 W4
// merged the old `nros::ComponentNode` into `rclcpp::Node`; phase-503 moved
// the C++ headers to `<rclcpp/*>` and dropped the `nros::` namespace), and the
// test programs derive it too.
#include <memory>

#include <rclcpp/rclcpp.hpp>

// Phase 3 W1 - the node-argument type the vendored autoware components take
// (`AsiNode &`): the node they declare parameters on. `rclcpp::Node`, so any
// `NodeWithTimers<N>` derivation binds to it.
using AsiNode = rclcpp::Node;

// MPC/PID debug-publisher member declarations reference a global
// `Publisher<M>` (assignments disabled - see mpc.hpp). Alias it to the
// nros-cpp publisher now that the shim wrapper is gone.
template <typename M>
using Publisher = rclcpp::Publisher<M>;

#endif  // COMMON__NODE_HPP_
