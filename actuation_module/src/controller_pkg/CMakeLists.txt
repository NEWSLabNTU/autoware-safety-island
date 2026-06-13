# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 2.C / 242.5 (RFC-0044) — nano-ros Node pkg `controller_pkg`.
#
# This is the project-mode replacement for the pre-2.C `controller_pkg.cmake`
# include shim. It is its OWN `project(controller_pkg)` so that
# `nano_ros_node_register`'s L.4 identity rule (CLASS must start with
# `${PROJECT_NAME}::`) resolves to `controller_pkg::Controller`, and so the
# Phase 240.8 Zephyr typed-entry carrier inside the fn generates the bootable
# entry into the find_package(Zephyr)-owned `app` target.
#
# `add_subdirectory(src/controller_pkg)` from the outer
# `project(actuation_module)` composes this into the app build. SINGLE node:
# the carrier appends one generated `int main()` to `app` and links the
# component lib (`controller_pkg_controller_component`) into it.
#
# NOTE (ASI integration / reference-consumer): ASI consumes nano-ros as a west
# Zephyr *module* (`zephyr_library_named(nros)` + CONFIG_NROS_CPP_API), not via
# the standalone `add_subdirectory(nano-ros)` model. So `nano_ros_node_register`
# is not auto-available and `NANO_ROS_PLATFORM` is unset here — we include the
# fn module explicitly and set the platform key so the Zephyr carrier branch
# fires. The component lib is then given Zephyr's compile context + the nros-cpp
# / generated-message include paths (carried on `zephyr_interface` +
# globbed from the autoware_msgs codegen output dir) so the heavy autoware C++
# TUs compile with the same flags they had as `app` sources.

cmake_minimum_required(VERSION 3.22.1)
project(controller_pkg LANGUAGES C CXX)

# actuation_module root (this file lives at <root>/src/controller_pkg/).
get_filename_component(_ACT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# RFC-0044 facade: the value-returning ComponentNode parameter API + the
# std::string / std::vector<T> parameter overloads the vendored MPC/PID use are
# gated on NROS_CPP_STD. ASI's controller declares std::vector<double> weight
# matrices + std::string-keyed params, so it must compile with std mode on.
add_compile_definitions(NROS_CPP_STD=1)

# --- Gather the vendored autoware component sources + include dirs ----------
# The autoware components are plain implementation libs (roadmap gap I4), not
# nodes. Their `.cmake` snippets `list(APPEND APP_SOURCES …)` with paths
# relative to the actuation_module root; collect them here and absolutise so
# they compile in this subdir's scope (no walk-up, no project-root heuristics).
set(APP_SOURCES "")
set(APP_INCLUDE_DIRS "")
set(AUTOWARE_COMPONENTS
  autoware_universe_utils
  autoware_interpolation
  autoware_motion_utils
  autoware_vehicle_info_utils
  autoware_trajectory_follower_base
  autoware_mpc_lateral_controller
  autoware_pid_longitudinal_controller
  autoware_trajectory_follower_node
)
foreach(component IN LISTS AUTOWARE_COMPONENTS)
  include(${_ACT_ROOT}/src/autoware/${component}/${component}.cmake)
endforeach()

set(_controller_sources "")
foreach(_s IN LISTS APP_SOURCES)
  list(APPEND _controller_sources "${_ACT_ROOT}/${_s}")
endforeach()
# The component's own registration TU (carries NROS_COMPONENT(Controller)).
list(APPEND _controller_sources
  "${CMAKE_CURRENT_SOURCE_DIR}/src/controller.cpp")

set(_controller_includes "")
foreach(_i IN LISTS APP_INCLUDE_DIRS)
  list(APPEND _controller_includes "${_ACT_ROOT}/${_i}")
endforeach()

# --- Register the Node pkg + generate the Zephyr typed entry ----------------
include(${NROS_REPO_DIR}/cmake/NanoRosNodeRegister.cmake)
# Force the Zephyr carrier branch (the west-module path leaves this unset).
set(NANO_ROS_PLATFORM zephyr)

nano_ros_node_register(
  NAME    controller
  CLASS   controller_pkg::Controller
  LANGUAGE CXX
  TYPED
  SHAPE   rclcpp
  HEADER  controller_pkg/controller.hpp
  SOURCES ${_controller_sources}
  DEPLOY  zephyr
)

# --- Give the component lib the full Zephyr + nros-cpp + message context ----
set(_component controller_pkg_controller_component)
if(TARGET ${_component})
  # zephyr_interface carries every `zephyr_compile_*` flag / `-imacros autoconf.h`
  # / devicetree + the nano-ros module's `zephyr_include_directories(<nros-cpp>)`
  # so the autoware C++ TUs compile exactly as they did when they were `app`
  # sources. (The nano_ros_node_register CPP path links NanoRos::NanoRosCpp, which
  # does not exist on the west-module build — zephyr_interface supplies the
  # equivalent include set.)
  if(TARGET zephyr_interface)
    target_link_libraries(${_component} PRIVATE zephyr_interface)
  endif()

  # ASI common/ + platform/ headers (logger, clock, can, node shim, threading).
  target_include_directories(${_component} PRIVATE
    "${_ACT_ROOT}/include"
    ${_controller_includes}
    "${EIGEN3_INCLUDE_DIR}")

  # autoware_msgs INTERFACE target exposes the hand-written
  # `<autoware/autoware_msgs/messages.hpp>` umbrella include.
  if(TARGET autoware_msgs)
    target_link_libraries(${_component} PUBLIC autoware_msgs)
  endif()

  # nros codegen emits the generated C++ message headers under the autoware_msgs
  # subdir's binary tree (target_include_directories(app …) inside
  # nros_generate_interfaces). The component lib lives in a different directory
  # scope, so add those dirs explicitly. autoware_msgs is add_subdirectory'd from
  # the outer project BEFORE this pkg, so the dirs already exist at configure.
  set(_gen_base "${CMAKE_BINARY_DIR}/src/autoware/autoware_msgs/nano_ros_cpp")
  if(EXISTS "${_gen_base}")
    file(GLOB _gen_pkg_dirs LIST_DIRECTORIES true "${_gen_base}/*")
    target_include_directories(${_component} PRIVATE "${_gen_base}" ${_gen_pkg_dirs})
  endif()
  target_compile_definitions(${_component} PRIVATE PLATFORM_ZEPHYR=1)

  # FVP has no `fabsl`; same substitute the app used (matches outer CMakeLists).
  if(ZEPHYR_TARGET STREQUAL "fvp_baser_aemv8r_smp")
    target_compile_options(${_component} PRIVATE
      "-Dfabsl(x)=((long double)fabs((double)(x)))")
  endif()
endif()
