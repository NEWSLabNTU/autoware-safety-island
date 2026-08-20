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
# Phase 3 W2.b (nano-ros 287-W6) — the canonical workspace verb. On Zephyr,
# `find_package(nano_ros)` (in the workspace root, which add_subdirectory's
# us) supplies the verbs WITHOUT re-importing the runtime — the nano-ros west
# module already provides NanoRos::*. No DEPLOY: the component is registered
# CARRIER-LESS; the workspace-root `nano_ros_add_executable` assembles the
# bootable entry from the launch topology (replacing the phase-240.8 typed
# carrier + forced NANO_ROS_PLATFORM this file used to need).
nano_ros_add_node(controller
  CLASS   controller_pkg::Controller
  TYPED
  SHAPE   rclcpp
  HEADER  controller_pkg/controller.hpp
  SOURCES ${_controller_sources}
)

# --- Give the component lib the full Zephyr + nros-cpp + message context ----
set(_component controller_pkg_controller_component)
if(TARGET ${_component})
  # ASI common/ + platform/ headers (logger, clock, can, node shim, threading).
  # PUBLIC: the workspace lane's generated entry TU includes
  # controller_pkg/controller.hpp (which pulls the vendored controller tree)
  # and inherits these by linking the component.
  target_include_directories(${_component} PUBLIC
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
    target_include_directories(${_component} PUBLIC "${_gen_base}" ${_gen_pkg_dirs})
  endif()
  # Workspace lane (phase-4 W5.a): the canonical generator produces headers
  # at BUILD time and carries include dirs + the generation dependency on the
  # per-package `<pkg>__nano_ros_cpp` INTERFACE targets — link them (the glob
  # above sees empty dirs at configure there). No-op on the Zephyr lane,
  # whose module variant attaches everything to `app` at configure.
  foreach(_msgpkg builtin_interfaces std_msgs geometry_msgs nav_msgs
                  autoware_perception_msgs autoware_vehicle_msgs
                  autoware_planning_msgs autoware_control_msgs
                  autoware_adapi_v1_msgs tier4_debug_msgs)
    if(TARGET ${_msgpkg}__nano_ros_cpp)
      target_link_libraries(${_component} PUBLIC ${_msgpkg}__nano_ros_cpp)
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
  if(EXISTS "${_gen_base}")
    target_include_directories(app PRIVATE "${_gen_base}" ${_gen_pkg_dirs})
  endif()
  if(TARGET autoware_msgs)
    target_link_libraries(app PRIVATE autoware_msgs)
  endif()
  if(ZEPHYR_TARGET STREQUAL "fvp_baser_aemv8r_smp")
    target_compile_options(app PRIVATE
      "-Dfabsl(x)=((long double)fabs((double)(x)))")
  endif()
endif()
