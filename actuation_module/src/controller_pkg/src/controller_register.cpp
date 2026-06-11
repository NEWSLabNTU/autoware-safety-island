// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 2.A — nano-ros Node pkg identity declaration for `controller_pkg`.
//
// This is the C++ `NROS_NODE`-equivalent decl that nano-ros C++ Node
// pkgs use (see nano-ros `packages/core/nros-cpp/include/nros/node_pkg.hpp`
// + the cmake fn `nano_ros_node_register`). It stamps the per-pkg
// component register trampoline + the class-name marker
// `"controller_pkg::Controller"` that `nros check` / `nros codegen-system`
// consume to validate identity (I1) and resolve the node at codegen.
//
// GATED behind `NROS_WORKSPACE_MODE`. The live register path requires
// nano-ros Phase 235 (the C++ embedded NodeContext runtime) which is NOT
// yet landed — it is the hard dependency for ASI Phase 2.C (the C++ Entry
// pkg). ASI's pinned nano-ros (`modules/nros`, west pin 70ab6227d) still
// boots through the legacy `common/node` shim (`::nros::Node` /
// `::nros::create_node`), not the `NodeContext` component runtime. Until
// 2.C flips `NROS_WORKSPACE_MODE` on (with controller_pkg configured as
// its own cmake project so `nano_ros_node_register`'s `${PROJECT_NAME}::`
// prefix check resolves to `controller_pkg::`), this TU compiles to
// nothing and the working build is untouched.
//
// The declaration below is the blueprint 2.C activates: it creates the
// node from the de-scattered `DEFAULT_NODE_NAME` (I2). The publisher /
// subscription entity declarations (against the I3 declared-default
// topics) are wired alongside the Entry runtime in 2.C — the topic
// strings already live single-sourced in `node_identity.hpp`.

#ifdef NROS_WORKSPACE_MODE

// `NROS_PKG_NAME` is the pkg identity the `NROS_NODE` macro stringifies
// into the `"<pkg>::<UserClass>"` marker. In the canonical nano-ros build
// the cmake fn `nano_ros_node_register()` injects it via
// `target_compile_definitions`; ASI's monolithic Zephyr build defines it
// here so the marker reads `controller_pkg::Controller` regardless of the
// outer `project(actuation_module)` name.
#ifndef NROS_PKG_NAME
#define NROS_PKG_NAME controller_pkg
#endif

#include <nros/node_pkg.hpp>

#include "controller_pkg/controller.hpp"
#include "controller_pkg/node_identity.hpp"

namespace controller_pkg {

::nros::Result Controller::register_node(::nros::NodeContext& context) {
    // I2 — node name comes from the declared default, never a literal.
    ::nros::NodeOptions options =
        ::nros::NodeOptions::make(node_identity::DEFAULT_NODE_NAME);

    ::nros::DeclaredNode node;
    ::nros::Result result = context.create_node(node, options);
    if (!result.ok()) {
        return result;
    }

    // Phase 2.C — declare the 5 sub + 3 pub entities here against the
    // `node_identity::topics::*` declared defaults (the I3 single source),
    // then record the callback effects. Deferred with the embedded
    // NodeContext runtime (nano-ros Phase 235).
    return ::nros::Result::success();
}

}  // namespace controller_pkg

// Emits `__nros_component_controller_pkg_register`, the export-present
// marker, and the `"controller_pkg::Controller"` class-name marker.
NROS_NODE(Controller);

#endif  // NROS_WORKSPACE_MODE
