# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# controller_pkg: the Safety Island's one node, controller_pkg::Controller,
# registered as a nano-ros component (RFC-0057). The image's entry is
# generated from controller_bringup; this package names no board and no
# platform: those come from asi_common.

cmake_minimum_required(VERSION 3.22.1)
project(controller_pkg LANGUAGES C CXX)

# actuation_module root (this file lives at <root>/src/controller_pkg/).
get_filename_component(_ACT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# The platform layer and the Autoware controller library. Configured before
# this package in a workspace build; nano-ros's metadata probe adds this
# package on its own, so add them here when nobody did.
if(NOT TARGET asi_common)
  add_subdirectory("${_ACT_ROOT}/src/asi_common" asi_common)
endif()
if(NOT TARGET autoware_controller_libs)
  add_subdirectory("${_ACT_ROOT}/src/autoware" autoware_controller_libs)
endif()

# --- The component library + its registration (RFC-0057) -------------------
# nano-ros's reference shape, the ament analog: the library owns the sources,
# the register owns the identity. No DEPLOY: the component is registered
# carrier-less and each image's entry assembles the bootable binary from the
# bringup's launch topology.
nano_ros_auto_add_library(controller_lib STATIC
  src/controller.cpp
  autoware_trajectory_follower_node/src/controller_node.cpp)
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

# PUBLIC: the generated entry TU includes controller_pkg/controller.hpp, which
# pulls the vendored controller tree, and inherits all of this by linking the
# component.
target_include_directories(controller_lib PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_trajectory_follower_node/include")
target_link_libraries(controller_lib PUBLIC autoware_controller_libs asi_common asi_eigen)

# Per-topic delivery counters in the controller callbacks, for answering "at
# what RATE is this topic reaching the app?" -- a question the controller's own
# log cannot answer, because it only reports presence. Off unless asked for;
# they compile to nothing otherwise. See scripts/an536-rx-counters.py.
if(DEFINED ENV{ASI_RX_COUNTERS} OR ASI_RX_COUNTERS)
  target_compile_definitions(controller_lib PRIVATE ASI_RX_COUNTERS=1)
  message(STATUS "controller_pkg: ASI_RX_COUNTERS enabled (gdb-readable rx counters)")
endif()
target_compile_features(controller_lib PUBLIC cxx_std_17)

# --- Zephyr: the generated entry is compiled into `app` ----------------------
# nano_ros_entry() appends a generated main TU to `app` that includes the
# component HEADER and constructs the Controller, so `app` needs the same
# include context as the component library.
if(TARGET app)
  target_include_directories(app PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/autoware_trajectory_follower_node/include")
  target_link_libraries(app PRIVATE autoware_controller_libs asi_common asi_eigen)
endif()
