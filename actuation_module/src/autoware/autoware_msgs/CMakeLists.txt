# Copyright (c) 2022-2026, Arm Limited / NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.12)

project(autoware_msgs LANGUAGES C CXX)

# Phase 3 W1 (nano-ros branch) — DUAL-MODE message codegen:
#
#   * Zephyr platforms load the nano-ros module, which defines
#     `nros_generate_interfaces()` — messages are generated from the vendored
#     ROS `.msg` sources under msg_ros/ (nros codegen, CPP bindings).
#   * FreeRTOS platforms (freertos-posix / freertos-s32z2) build WITHOUT
#     nano-ros — they keep upstream's CycloneDDS `idlc` path over msg/*.idl.
#
# Selector: the presence of the nano-ros command, not a platform flag, so a
# future nano-ros FreeRTOS adoption (phase-3 W5) flips per-build without
# touching this file.
if(COMMAND nros_generate_interfaces)
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
  # Workspace lane (phase-4 W5.a, freertos-posix): the canonical
  # nros_generate_interfaces() wires INSTALL(EXPORT <pkg>Targets), which an
  # in-app aggregation never populates — pass SKIP_INSTALL there. The Zephyr
  # module variant does not parse the flag (it would read it as a message
  # path), so gate on the lane.
  if(TARGET zephyr_interface)
      set(_asi_gen_extra "")
  else()
      set(_asi_gen_extra SKIP_INSTALL)
  endif()
  function(_asi_gen pkg)
      cmake_parse_arguments(_a "" "" "DEPENDENCIES" ${ARGN})
      file(GLOB _msgs RELATIVE ${CMAKE_CURRENT_SOURCE_DIR}
          "${_msg_ros_root}/${pkg}/msg/*.msg")
      nros_generate_interfaces(${pkg} ${_msgs} LANGUAGE CPP
          DEPENDENCIES ${_a_DEPENDENCIES} ${_asi_gen_extra})
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
else()
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
endif()
