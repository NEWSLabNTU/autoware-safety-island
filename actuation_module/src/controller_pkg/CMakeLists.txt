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

# The vendored Autoware packages the node uses, <depend>s in package.xml:
# the workspace build and nano-ros's metadata probe add them (and
# asi_common) before this package (nano-ros issue 2680).
set(_AUTOWARE_DEPS
  autoware_motion_utils
  autoware_mpc_lateral_controller
  autoware_pid_longitudinal_controller
  autoware_trajectory_follower_base
  autoware_universe_utils
  autoware_vehicle_info_utils)

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
target_link_libraries(controller_lib PUBLIC ${_AUTOWARE_DEPS} asi_common)

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
  target_link_libraries(app PRIVATE ${_AUTOWARE_DEPS} asi_common)
endif()

# --- FreeRTOS POSIX: the SocketCAN vcan sender (build.sh --can-output-test) --
# A host test program, not part of the image: it drives the controller's CAN
# output stack (encoder + SocketCAN backend) against a Linux vcan0, for
# actuation_module/test/run-vcan-roundtrip.sh. It compiles against the
# component library for the message types; can_vcan_sender_log.c stands in
# for the nros log calls, so nothing of the nros runtime or the FreeRTOS
# kernel is linked and the program keeps its own main(). Placed next to the
# image entry, where build.sh finds it.
option(ASI_CAN_VCAN_SENDER
  "build the SocketCAN vcan sender test program (FreeRTOS POSIX only)" OFF)
# Other configures (Zephyr, the ARMv8-R boards, nano-ros's host metadata
# probe) ignore it.
if(ASI_CAN_VCAN_SENDER AND NOT TARGET app AND NROS_PLATFORM STREQUAL "freertos"
   AND NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "cortex-r52")
  # The program's sources, compiled in the component library's context
  # (headers and defines, followed through its links), not linked to it:
  # asi_common carries the POSIX board hook as an object, and the nros runtime
  # archives pull in the kernel.
  add_library(can_vcan_sender_obj OBJECT
    "${_ACT_ROOT}/test/can_vcan_sender.cpp"
    "${_ACT_ROOT}/test/can_vcan_sender_log.c")
  target_include_directories(can_vcan_sender_obj PRIVATE
    $<TARGET_PROPERTY:controller_lib,INCLUDE_DIRECTORIES>)
  target_compile_definitions(can_vcan_sender_obj PRIVATE
    $<TARGET_PROPERTY:controller_lib,COMPILE_DEFINITIONS>)
  target_compile_features(can_vcan_sender_obj PRIVATE cxx_std_17)
  target_compile_options(can_vcan_sender_obj PRIVATE -Wall -Wextra -Wno-unused-parameter)
  # The generated nros config headers come from the same build steps
  # controller_lib waits on.
  add_dependencies(can_vcan_sender_obj controller_lib)
  # The config-variant anchors those headers plant (can_vcan_sender_variant.cmake).
  set(_variant_c "${CMAKE_CURRENT_BINARY_DIR}/can_vcan_sender_variant.c")
  add_custom_command(OUTPUT "${_variant_c}"
    COMMAND "${CMAKE_COMMAND}" -DNM=${CMAKE_NM}
      "-DOBJS=$<TARGET_OBJECTS:can_vcan_sender_obj>" -DOUT=${_variant_c}
      -P "${_ACT_ROOT}/test/can_vcan_sender_variant.cmake"
    DEPENDS can_vcan_sender_obj $<TARGET_OBJECTS:can_vcan_sender_obj>
      "${_ACT_ROOT}/test/can_vcan_sender_variant.cmake"
    COMMAND_EXPAND_LISTS
    VERBATIM)
  # A plain host program with its own main(). On a board platform nano-ros
  # turns every add_executable into an image (the board's entry calls the
  # program's renamed main, phase-518); nano_ros_add_plain_executable is its
  # stated way out (nano-ros issue 2678, PR 4016).
  nano_ros_add_plain_executable(can_vcan_sender
    $<TARGET_OBJECTS:can_vcan_sender_obj> "${_variant_c}")
  # nano-ros's SocketCAN backend of the platform CAN frame driver: the
  # library the freertos-posix image's entry links for its
  # [image.<id>.can] device (cmake/NanoRosCanImage.cmake), so this program
  # sends through the same backend. It opens vcan0 by name.
  target_link_libraries(can_vcan_sender PRIVATE nros_can_socketcan pthread)
  set_target_properties(can_vcan_sender PROPERTIES
    LINKER_LANGUAGE CXX
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
endif()
