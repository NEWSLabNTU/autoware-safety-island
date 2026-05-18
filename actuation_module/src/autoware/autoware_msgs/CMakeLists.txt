# Copyright (c) 2022-2023, Arm Limited.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.12)

project(autoware_msgs LANGUAGES C CXX)

# Phase 1B / 1C migration toggle. ON = generate via nros codegen from
# the vendored upstream .msg tree under msg_ros/. OFF (default) = the
# legacy CycloneDDS idlc path below. Switch is propagated from the
# top-level CMakeLists via -DASI_USE_NANO_ROS=ON (build.sh
# --nano-ros-shim).
if(ASI_USE_NANO_ROS)
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
        # nros_generate_interfaces resolves file paths relative to
        # CMAKE_CURRENT_SOURCE_DIR — pass relative paths so the
        # concatenation produces the right absolute path.
        file(GLOB _msgs RELATIVE ${CMAKE_CURRENT_SOURCE_DIR}
            "${_msg_ros_root}/${pkg}/msg/*.msg")
        nros_generate_interfaces(${pkg} ${_msgs} LANGUAGE CPP
            DEPENDENCIES ${_a_DEPENDENCIES})
        # Re-export ${pkg}_GENERATED_RS_FILES set by the function so
        # subsequent calls see the deps' generated-file list.
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

    # Public include dir for ASI's hand-written
    # `<autoware/autoware_msgs/messages.hpp>` umbrella (Trajectory wrapper +
    # cap). Expose only via an INTERFACE target so legacy linker entries
    # like `target_link_libraries(app PRIVATE autoware_msgs)` continue to
    # compile cleanly when ASI_USE_NANO_ROS=ON.
    add_library(${PROJECT_NAME} INTERFACE)
    target_include_directories(${PROJECT_NAME} INTERFACE
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)

    return()  # skip the legacy idlc block below
endif()

# ============================================================================
# Legacy raw-Cyclone path (default, until ASI_USE_NANO_ROS becomes default).
# ============================================================================

# idlc is a host tool, and doesn't care about the architecture of the target platform.
# Prevent cmake from checking the architecture by temporarily unsetting CMAKE_SIZEOF_VOID_P.
set(TMP_CMAKE_SIZEOF_VOID_P ${CMAKE_SIZEOF_VOID_P})
unset(CMAKE_SIZEOF_VOID_P)
find_package(CycloneDDS REQUIRED COMPONENTS ddsc idlc)
set(CMAKE_SIZEOF_VOID_P ${TMP_CMAKE_SIZEOF_VOID_P})

file(GLOB IDL_FILES msg/*.idl)
list(TRANSFORM IDL_FILES REPLACE "\\.idl" ".c" OUTPUT_VARIABLE SOURCES)
list(TRANSFORM SOURCES REPLACE ".*/" "${CMAKE_CURRENT_BINARY_DIR}/")
list(TRANSFORM SOURCES REPLACE "\\.c$" ".h" OUTPUT_VARIABLE HEADERS)

execute_process(
  COMMAND idlc -v
  OUTPUT_VARIABLE IDLC_VERSION_OUTPUT
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE IDLC_VERSION_RESULT
)

if(NOT IDLC_VERSION_RESULT EQUAL 0)
  message(WARNING "Failed to get idlc version. Exit code: ${IDLC_VERSION_RESULT}")
else()
  message(STATUS "IDLC Version: ${IDLC_VERSION_OUTPUT}")
endif()

# Generate source files and headers for the DDS messages.
# Edit out potential absolute path to the source .idl from the resulting .c and .h files.
add_custom_command(
  OUTPUT ${SOURCES} ${HEADERS}
  COMMAND /bin/sh -c "find ${CMAKE_CURRENT_SOURCE_DIR}/msg/ -maxdepth 1 -name '*.idl' -exec idlc {} \\; && sed -i -- 's|/\\(.\\+\\)/\\(.*\\.idl\\)|\\2|' *.h *.c"
  DEPENDS ${IDL_FILES}
  VERBATIM
)

# --- ORIGINAL ---
# add_library(${PROJECT_NAME}
#   ${SOURCES}
#   ${HEADERS}
# )
# set_target_properties(${PROJECT_NAME} PROPERTIES
#   LINKER_LANGUAGE CXX
# )

# --- Platform-aware library build ---
if(PLATFORM_ZEPHYR)
  zephyr_library_named(${PROJECT_NAME})
  target_sources(${PROJECT_NAME} PRIVATE ${SOURCES} ${HEADERS})
else()
  add_library(${PROJECT_NAME} STATIC ${SOURCES} ${HEADERS})
  set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)
endif()

get_target_property(CycloneDDS_INCLUDE_DIR CycloneDDS::ddsc INTERFACE_INCLUDE_DIRECTORIES)
target_include_directories(${PROJECT_NAME} SYSTEM BEFORE PUBLIC
  ${CycloneDDS_INCLUDE_DIR}
  ${CMAKE_CURRENT_BINARY_DIR}
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
)

# --- ORIGINAL INSTALL (commented, because Zephyr libs are not getting) ---
# install(TARGETS ${PROJECT_NAME} DESTINATION lib)
# install(
#   FILES ${HEADERS}
#   DESTINATION include/autoware/autoware_msgs
# )
# install(
#   DIRECTORY include/autoware/
#   DESTINATION include/autoware
# )
