# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 2.A — nano-ros Node pkg `controller_pkg`.
#
# Mirrors the vendored component `.cmake` include shape
# (list(APPEND APP_*) into the actuation_module monolithic Zephyr build)
# but carries ASI's node identity instead of a plain library.
#
# The controller_pkg headers (the `controller_pkg::Controller` wrapper +
# the single-source `node_identity.hpp` declared defaults) are always on
# the include path so `main.cpp` and the vendored controller TU resolve
# them.

list(APPEND APP_INCLUDE_DIRS
  src/controller_pkg/include
)

# ---------------------------------------------------------------------------
# Node identity declaration (the C++ NROS_NODE-equivalent decl).
#
# GATED behind NROS_WORKSPACE_MODE. The live component register path
# depends on nano-ros Phase 235 (the C++ embedded NodeContext runtime),
# which is the hard dependency for ASI Phase 2.C. Until 2.C, ASI boots
# through the legacy `common/node` shim, so this compiles to nothing and
# the working build is unchanged.
#
# Phase 2.C will instead lift controller_pkg into its OWN cmake project
# (`project(controller_pkg)`) and call nano-ros's
#   nano_ros_node_register(NAME controller CLASS controller_pkg::Controller
#                          LANGUAGE CPP SOURCES src/controller_register.cpp
#                          DEPLOY fvp-aemv8r-smp)
# — that fn enforces the `${PROJECT_NAME}::` (== controller_pkg::) prefix
# rule and writes nros-metadata.json for `nros check`. It cannot run inside
# the monolithic `project(actuation_module)` build because PROJECT_NAME
# would be `actuation_module`, not `controller_pkg`.
# ---------------------------------------------------------------------------
option(NROS_WORKSPACE_MODE
  "Compile the controller_pkg nano-ros component node decl (Phase 2.C; needs nano-ros Phase 235)"
  OFF)

if(NROS_WORKSPACE_MODE)
  list(APPEND APP_SOURCES
    src/controller_pkg/src/controller_register.cpp
  )
  target_compile_definitions(app PRIVATE NROS_WORKSPACE_MODE=1)
endif()
