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
# component lib (`controller_lib`) into it.
#
# NOTE (ASI integration / reference-consumer): ASI consumes nano-ros as a west
# Zephyr *module* (`zephyr_library_named(nros)` + CONFIG_NROS_CPP_API), not via
# the standalone `add_subdirectory(nano-ros)` model. So `nano_ros_node_register`
# is not auto-available and `NANO_ROS_PLATFORM` is unset here — we include the
# fn module explicitly and set the platform key so the Zephyr carrier branch
# fires. The component lib is then given Zephyr's compile context + the nros-cpp
# / generated-message include paths (carried on `zephyr_interface` and `app`)
# so the heavy autoware C++ TUs compile with the same flags they had as `app`
# sources.

cmake_minimum_required(VERSION 3.22.1)
project(controller_pkg LANGUAGES C CXX)

# actuation_module root (this file lives at <root>/src/controller_pkg/).
get_filename_component(_ACT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Eigen, when nobody above us resolved it.
#
# The parent actuation_module/CMakeLists.txt normally does this (and may patch
# the headers for the cross build), so in the ordinary build this is a no-op.
# But this package is also added as a SUBDIRECTORY on its own, by nano-ros's
# metadata probe, where no parent runs — EIGEN3_INCLUDE_DIR is then empty and
# the vendored Autoware geometry headers fail at `#include <Eigen/Core>`.
# Depending on a variable a parent happens to set is what made this package
# unusable standalone (surfaced by nano-ros issue 0939).
if(NOT EIGEN3_INCLUDE_DIR)
  find_package(Eigen3 QUIET)
  if(NOT EIGEN3_INCLUDE_DIR AND TARGET Eigen3::Eigen)
    get_target_property(EIGEN3_INCLUDE_DIR Eigen3::Eigen INTERFACE_INCLUDE_DIRECTORIES)
  endif()
endif()

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

# Bare-metal FreeRTOS (an536, s32z2) has NO wall clock: nano-ros's platform
# reports none (issue 0758) and newlib's _gettimeofday stub answers with
# garbage, so every stamped control command is garbage too and no ROS peer will
# accept it. This TU supplies one (SNTP epoch + the monotonic platform clock).
# The FreeRTOS POSIX simulator is excluded on purpose — there the host clock is
# already correct, which is what platform/freertos/freertos_clock.h assumes.
if(_asi_is_armv8r)
  list(APPEND _controller_sources
    "${_ACT_ROOT}/src/platform/freertos/wall_clock.cpp")
  add_compile_definitions(ASI_FREERTOS_WALL_CLOCK=1)
endif()

# Per-topic delivery counters in the controller callbacks, for answering "at
# what RATE is this topic reaching the app?" — a question the controller's own
# log cannot answer, because it only reports presence. Off unless asked for;
# they compile to nothing otherwise. See scripts/an536-rx-counters.py.
if(DEFINED ENV{ASI_RX_COUNTERS} OR ASI_RX_COUNTERS)
  add_compile_definitions(ASI_RX_COUNTERS=1)
  message(STATUS "controller_pkg: ASI_RX_COUNTERS enabled (gdb-readable rx counters)")
endif()

set(_controller_includes "")
foreach(_i IN LISTS APP_INCLUDE_DIRS)
  list(APPEND _controller_includes "${_ACT_ROOT}/${_i}")
endforeach()

# --- The component library + its registration (RFC-0057) -------------------
# nano-ros's reference shape, the ament analog: the library owns the sources,
# the register owns the identity. No DEPLOY: the component is registered
# carrier-less and each image's entry assembles the bootable binary from the
# bringup's launch topology.
nano_ros_auto_add_library(controller_lib STATIC ${_controller_sources})
nros_components_register_node(controller_lib
  PLUGIN     controller_pkg::Controller
  EXECUTABLE controller
  TYPED
  SHAPE      rclcpp
  HEADER     controller_pkg/controller.hpp
  # The control timer's group; bound to [tasks.control] by
  # controller_bringup/system.toml group_tasks.
  CALLBACK_GROUPS control
)

# --- Give the component lib the full Zephyr + nros-cpp + message context ----
set(_component controller_lib)
if(TARGET ${_component})
  # ASI common/ + platform/ headers (logger, clock, can, node shim, threading).
  # PUBLIC: the workspace lane's generated entry TU includes
  # controller_pkg/controller.hpp (which pulls the vendored controller tree)
  # and inherits these by linking the component.
  target_include_directories(${_component} PUBLIC
    "${_ACT_ROOT}/include"
    ${_controller_includes}
    "${EIGEN3_INCLUDE_DIR}")

  # State the language standard on the TARGET rather than inheriting whatever
  # the enclosing project set. Same reason as the Eigen block
  # (nano-ros issue 0939): this package is add_subdirectory'd standalone by the
  # nros metadata probe, whose generated CMakeLists sets `CMAKE_CXX_STANDARD 14`
  # — and the vendored Autoware tree is C++17 (`alt_geometry.hpp` alone uses
  # `std::optional` a dozen times). Without this the probe fails with
  # "'optional' in namespace 'std' does not name a template type", which names
  # the symbol and not the cause.
  #
  # A FLOOR, not a pin. `set_target_properties(CXX_STANDARD 17)` sets the
  # standard EXACTLY, which silently downgrades a parent that selected a later
  # one — and the main build does select a later one. `cxx_std_17` says "at
  # least 17", which is the actual requirement: raise the probe's 14, leave
  # everything else alone.
  target_compile_features(${_component} PUBLIC cxx_std_17)

  # Messages: nano_ros_auto_add_library() above generated every message
  # package package.xml <depend>s on and linked the generated libraries (on
  # Zephyr their headers reach `app`, whose include directories the library
  # inherits). The hand-written umbrella <autoware/autoware_msgs/messages.hpp>
  # is in this package's include/.
  #
  # The two message packages of this workspace were generated by their own
  # rosidl_generate_interfaces() before this package configured, so the verb
  # finds them already built and does not link them. Link their targets.
  foreach(_msgpkg visionpilot_msgs safety_island_msgs)
    if(TARGET ${_msgpkg}::${_msgpkg})
      target_link_libraries(${_component} PUBLIC ${_msgpkg}::${_msgpkg})
    endif()
  endforeach()

  if(TARGET zephyr_interface)
    target_compile_definitions(${_component} PRIVATE PLATFORM_ZEPHYR=1)
  else()
    # Workspace lane runs on the FreeRTOS POSIX simulator board. PUBLIC —
    # the generated entry TU compiles the same platform-dispatch headers.
    target_compile_definitions(${_component} PUBLIC PLATFORM_FREERTOS=1 NROS_CPP_STD=1)
    # platform_config.h wants the legacy Kconfig-mirror header. DDS knobs in
    # it are inert on this lane (nano-ros owns transport); logger/CAN/thread
    # values mirror the retired actuation_module/freertos/CMakeLists.txt
    # defaults (DDS_AND_CAN keeps the mock CAN path exercised).
    set(CONFIG_LOG_LEVEL 1)
    set(CONFIG_LOG_THROTTLE_RATE 3)
    set(CONFIG_DDS_DOMAIN_ID 2)
    set(CONFIG_DDS_NETWORK_INTERFACE "lo")
    set(CONFIG_DDS_LOG_LEVEL 0)
    set(CONFIG_THREAD_STACK_SIZE 262144)
    set(CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX 0)
    set(CONFIG_ENABLE_SNTP OFF)
    set(CONFIG_CONTROL_CMD_OUTPUT_DDS_ONLY 0)
    set(CONFIG_CONTROL_CMD_OUTPUT_CAN_ONLY 0)
    set(CONFIG_CONTROL_CMD_OUTPUT_DDS_AND_CAN 1)
    set(CONFIG_CONTROL_CMD_CAN_OUTPUT 1)
    set(CONFIG_CONTROL_CMD_DDS_OUTPUT 1)
    configure_file(
      "${_ACT_ROOT}/include/platform/freertos/freertos_config_generated.h.in"
      "${CMAKE_CURRENT_BINARY_DIR}/generated/freertos_config_generated.h")
    target_include_directories(${_component} PUBLIC
      "${CMAKE_CURRENT_BINARY_DIR}/generated"
      "${_ACT_ROOT}/include/platform/freertos")
  endif()

  # FVP has no `fabsl`; same substitute the app used (matches outer CMakeLists).
  if(ZEPHYR_TARGET STREQUAL "fvp_baser_aemv8r_smp")
    target_compile_options(${_component} PRIVATE
      "-Dfabsl(x)=((long double)fabs((double)(x)))")
  endif()
endif()

# --- Give the generated entry (compiled into `app`) the same include context --
# nano_ros_node_register (SHAPE rclcpp + TYPED) appends a generated
# `zephyr_entry_main.cpp` to `app` that `#include`s the component HEADER
# (controller_pkg/controller.hpp) and placement-news the Controller — so it
# pulls the full Autoware include chain (controller_node.hpp → … → Eigen) and
# the generated message headers, exactly like the component lib above. `app`
# only carries the nano-ros module + ASI common/ dirs, so add the rest here.
if(TARGET app)
  target_include_directories(app PRIVATE
    "${_ACT_ROOT}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    ${_controller_includes}
    "${EIGEN3_INCLUDE_DIR}")
  if(ZEPHYR_TARGET STREQUAL "fvp_baser_aemv8r_smp")
    target_compile_options(app PRIVATE
      "-Dfabsl(x)=((long double)fabs((double)(x)))")
  endif()
endif()
