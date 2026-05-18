# Copyright (c) 2022-2026, Arm Limited / NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.12)

project(autoware_msgs LANGUAGES C CXX)

set(_msg_ros_root ${CMAKE_CURRENT_SOURCE_DIR}/msg_ros)

# All nros_generate_interfaces() calls live in THIS scope (not via
# add_subdirectory) so the PARENT_SCOPE propagation of
# `${target}_GENERATED_RS_FILES` inside the function lands in our
# scope, where subsequent dep-walking calls can see it. With
# add_subdirectory each call's PARENT_SCOPE would only reach the
# per-pkg subdir scope, breaking the cross-package FFI include
# chain. (Per-pkg msg_ros/<pkg>/CMakeLists.txt stubs are kept on
# disk for documentation of dependency intent; they are no longer
# add_subdirectory'd.)
function(_asi_gen pkg)
    cmake_parse_arguments(_a "" "" "DEPENDENCIES" ${ARGN})
    file(GLOB _msgs RELATIVE ${CMAKE_CURRENT_SOURCE_DIR}
        "${_msg_ros_root}/${pkg}/msg/*.msg")
    nros_generate_interfaces(${pkg} ${_msgs} LANGUAGE CPP
        DEPENDENCIES ${_a_DEPENDENCIES})
    set(${pkg}_GENERATED_RS_FILES "${${pkg}_GENERATED_RS_FILES}" PARENT_SCOPE)
endfunction()

# NOTE: nros_generate_interfaces() does NOT walk DEPENDENCIES
# transitively when building the FFI lib.rs include!() set. Every
# ROS-package whose types appear in the generated code — even via
# nested fields like Header -> Time — must be listed explicitly.
_asi_gen(builtin_interfaces)
_asi_gen(std_msgs                 DEPENDENCIES builtin_interfaces)
_asi_gen(geometry_msgs            DEPENDENCIES std_msgs builtin_interfaces)
_asi_gen(nav_msgs                 DEPENDENCIES std_msgs geometry_msgs builtin_interfaces)
_asi_gen(autoware_perception_msgs DEPENDENCIES std_msgs geometry_msgs builtin_interfaces)
_asi_gen(autoware_vehicle_msgs    DEPENDENCIES std_msgs builtin_interfaces geometry_msgs)
_asi_gen(autoware_planning_msgs   DEPENDENCIES std_msgs geometry_msgs builtin_interfaces)
_asi_gen(autoware_control_msgs    DEPENDENCIES std_msgs builtin_interfaces)
_asi_gen(autoware_adapi_v1_msgs   DEPENDENCIES builtin_interfaces std_msgs geometry_msgs)
_asi_gen(tier4_debug_msgs         DEPENDENCIES builtin_interfaces std_msgs)

# INTERFACE target exposes ASI's hand-written
# `<autoware/autoware_msgs/messages.hpp>` umbrella (Trajectory wrapper + cap).
add_library(${PROJECT_NAME} INTERFACE)
target_include_directories(${PROJECT_NAME} INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
