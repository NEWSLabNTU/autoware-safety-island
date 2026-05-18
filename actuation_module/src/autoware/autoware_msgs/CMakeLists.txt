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

    # Topological order: each package can only DEPENDENCIES-reference a
    # package that came before it. nros_generate_interfaces is provided
    # by the nros Zephyr module under CONFIG_NROS=y (no find_package
    # needed — the helper is included from
    # `${ZEPHYR_NROS_MODULE_DIR}/cmake/nros_generate_interfaces.cmake`
    # which the module's CMakeLists.txt already pulls in for the
    # NROS_CPP_API path). Each call attaches generated artefacts (header
    # dir + Rust FFI staticlib + link to `app`) directly; there is no
    # per-package CMake target to link against on Zephyr.
    add_subdirectory(${_msg_ros_root}/builtin_interfaces        builtin_interfaces)
    add_subdirectory(${_msg_ros_root}/std_msgs                  std_msgs)
    add_subdirectory(${_msg_ros_root}/geometry_msgs             geometry_msgs)
    add_subdirectory(${_msg_ros_root}/nav_msgs                  nav_msgs)
    add_subdirectory(${_msg_ros_root}/autoware_perception_msgs  autoware_perception_msgs)
    add_subdirectory(${_msg_ros_root}/autoware_vehicle_msgs     autoware_vehicle_msgs)
    add_subdirectory(${_msg_ros_root}/autoware_planning_msgs    autoware_planning_msgs)
    add_subdirectory(${_msg_ros_root}/autoware_control_msgs     autoware_control_msgs)
    add_subdirectory(${_msg_ros_root}/autoware_adapi_v1_msgs    autoware_adapi_v1_msgs)
    add_subdirectory(${_msg_ros_root}/tier4_debug_msgs          tier4_debug_msgs)

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
