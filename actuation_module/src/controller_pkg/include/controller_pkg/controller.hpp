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
#include "common/logger/logger.hpp"

#if defined(CONFIG_ASI_RT_PROBE_REPORT)
#include <inttypes.h>

#include "nros/nros_cpp_ffi.h"  // nros_cpp_executor_release_jitter / _last_park
#endif

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
    /// Boot-status markers around base construction. The legacy imperative
    /// boot (`src/main.cpp`, retired with the generated Entry) printed these;
    /// the CI runtime smoke (`run-zephyr-fvp-ci.sh` phase 1) greps them, so
    /// the component ctor owns them now: "Starting" before the base wires the
    /// 5 subscriptions + 3 publishers + control timer, "Started"/"Live" once
    /// construction (entity creation) succeeded — a ctor throw ends the boot
    /// before the markers, which is exactly the failure CI should catch.
    explicit Controller(nros::NodeHandle handle)
        : ::autoware::motion::control::trajectory_follower_node::Controller(
              (common::logger::log_info("Starting Controller Node...\n"), handle))
#if defined(CONFIG_ASI_RT_PROBE_REPORT)
        , executor_(handle.executor)
#endif
    {
        common::logger::log_success("Controller Node Started\n");
        common::logger::log_success("Actuation Safety Island is Live\n");
#if defined(CONFIG_ASI_RT_PROBE_REPORT)
        create_wall_timer<Controller, &Controller::report_rt_probes>(
            CONFIG_ASI_RT_PROBE_REPORT_INTERVAL_MS);
#endif
    }

#if defined(CONFIG_ASI_RT_PROBE_REPORT)
  private:
    /// nano-ros phase-436 A3: one "rt-probe:" line per interval from the
    /// executor this node runs on, covering THAT interval only. The
    /// statistics are cleared after each report: the executor's own maximum
    /// is since boot, and the boot transient (~34 ms on FVP) otherwise pins it
    /// for the life of the process, hiding everything the steady state does.
    /// granularity_us is what the figure is worth; park_source is
    /// NROS_CPP_WAKE_SOURCE_* / platform index, for the last park only.
    void report_rt_probes()
    {
        uint64_t max_us = 0, granularity_us = 0, bound_us = 0, achieved_us = 0;
        uint32_t late = 0, total = 0;
        uint8_t source = 0, index = 0;
        if (nros_cpp_executor_release_jitter(executor_, &max_us, &late, &total,
                                             &granularity_us) != NROS_CPP_RET_OK ||
            nros_cpp_executor_last_park(executor_, &bound_us, &achieved_us, &source,
                                        &index) != NROS_CPP_RET_OK) {
            common::logger::log_warn("rt-probe: the executor refused the readout\n");
            return;
        }
        common::logger::log_info(
            "rt-probe: window_ms=%u jitter_max_us=%" PRIu64 " late=%" PRIu32
            " total=%" PRIu32
            " granularity_us=%" PRIu64 " park_bound_us=%" PRIu64
            " park_achieved_us=%" PRIu64 " park_source=%u/%u\n",
            static_cast<unsigned>(CONFIG_ASI_RT_PROBE_REPORT_INTERVAL_MS), max_us, late,
            total, granularity_us, bound_us, achieved_us, static_cast<unsigned>(source),
            static_cast<unsigned>(index));
        (void)nros_cpp_executor_clear_release_jitter_stats(executor_);
    }

    void* executor_;
#endif
};

}  // namespace controller_pkg

#endif  // CONTROLLER_PKG__CONTROLLER_HPP_
