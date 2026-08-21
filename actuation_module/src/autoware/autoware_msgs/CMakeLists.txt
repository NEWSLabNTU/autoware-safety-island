# Copyright (c) 2022-2026, Arm Limited / NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.12)

project(autoware_msgs LANGUAGES C CXX)

# Phase 3 W1 (nano-ros branch) — DUAL-MODE message codegen:
#
#   * Zephyr platforms load the nano-ros module, which defines
#     `nros_generate_interfaces()` — messages are generated from `.msg`
#     sources resolved via the AMENT environment (nros codegen, CPP bindings).
#   * FreeRTOS platforms (freertos-posix / freertos-s32z2) build WITHOUT
#     nano-ros — they keep upstream's CycloneDDS `idlc` path over msg/*.idl.
#
# Selector: the presence of the nano-ros command, not a platform flag, so a
# future nano-ros FreeRTOS adoption (phase-3 W5) flips per-build without
# touching this file.
if(COMMAND nros_generate_interfaces)
  # Phase 5 W1 — messages resolve from the AMENT environment, not a vendored
  # copy. The explicit per-package file lists below are the SAME deliberate
  # subset the retired msg_ros/ tree carried (footprint control: only what the
  # controller consumes is generated); nros_generate_interfaces resolves each
  # `msg/X.msg` relpath through AMENT_PREFIX_PATH/share/<pkg>/msg/X.msg.
  # Requirements: a sourced ROS 2 Humble env for the core packages and an
  # Autoware install for the autoware_* / tier4_* packages (the devcontainer
  # base image carries both; on a bare host, source ROS + an Autoware env or
  # extend AMENT_PREFIX_PATH — build.sh adds existence-gated defaults).
  #
  # ONE local override survives: Trajectory.msg bounds the point sequence at
  # [<=250] where upstream is unbounded — the embedded FixedSequence capacity
  # the controller is sized against. It lives under msg_overrides/ and is
  # resolved LOCALLY (relpath under CMAKE_CURRENT_SOURCE_DIR wins over ament).
  # A trajectory with more than 250 points fails deserialization, so keep the
  # bound in sync with the subscription buffer sizing in build.sh.

  # All nros_generate_interfaces() calls live in THIS scope (not via
  # add_subdirectory) so the PARENT_SCOPE propagation of
  # `${target}_GENERATED_RS_FILES` lands here, where the later dep-walking
  # calls can see it.
  #
  # Plain nano-ros macro calls, no ASI wrapper (phase-5 principle: ASI holds
  # production logic; ROS infra lives in nano-ros). SKIP_INSTALL is passed
  # unconditionally: the canonical (workspace) variant needs it (an in-app
  # aggregation never populates the INSTALL(EXPORT) layout) and the Zephyr
  # module variant accepts-and-ignores it (parity since nano-ros Phase
  # 210.E.3.c — verified, nano-ros issue 0753; the old lane gate here
  # guarded against a misparse that no current pin has).
  set(_nros_skip_install SKIP_INSTALL)

  # NOTE: nros_generate_interfaces() does NOT walk DEPENDENCIES
  # transitively when building the FFI lib.rs include!() set. Every
  # ROS-package whose types appear in the generated code — even via
  # nested fields like Header -> Time — must be listed explicitly.
  nros_generate_interfaces(builtin_interfaces
      msg/Duration.msg msg/Time.msg
      LANGUAGE CPP ${_nros_skip_install})
  nros_generate_interfaces(std_msgs
      msg/Header.msg
      LANGUAGE CPP DEPENDENCIES builtin_interfaces ${_nros_skip_install})
  nros_generate_interfaces(geometry_msgs
      msg/Accel.msg msg/AccelStamped.msg msg/AccelWithCovariance.msg
      msg/AccelWithCovarianceStamped.msg msg/Point.msg msg/Pose.msg
      msg/PoseArray.msg msg/PoseStamped.msg msg/PoseWithCovariance.msg
      msg/PoseWithCovarianceStamped.msg msg/Quaternion.msg
      msg/QuaternionStamped.msg msg/Transform.msg msg/TransformStamped.msg
      msg/Twist.msg msg/TwistStamped.msg msg/TwistWithCovariance.msg
      msg/TwistWithCovarianceStamped.msg msg/Vector3.msg msg/Vector3Stamped.msg
      LANGUAGE CPP DEPENDENCIES std_msgs builtin_interfaces ${_nros_skip_install})
  nros_generate_interfaces(nav_msgs
      msg/Odometry.msg
      LANGUAGE CPP DEPENDENCIES std_msgs geometry_msgs builtin_interfaces
      ${_nros_skip_install})
  nros_generate_interfaces(autoware_perception_msgs
      msg/PredictedPath.msg
      LANGUAGE CPP DEPENDENCIES std_msgs geometry_msgs builtin_interfaces
      ${_nros_skip_install})
  nros_generate_interfaces(autoware_vehicle_msgs
      msg/SteeringReport.msg msg/VelocityReport.msg
      LANGUAGE CPP DEPENDENCIES std_msgs builtin_interfaces geometry_msgs
      ${_nros_skip_install})
  nros_generate_interfaces(autoware_planning_msgs
      msg/Path.msg msg/PathPoint.msg msg/TrajectoryPoint.msg
      msg_overrides/autoware_planning_msgs/msg/Trajectory.msg
      LANGUAGE CPP DEPENDENCIES std_msgs geometry_msgs builtin_interfaces
      ${_nros_skip_install})
  nros_generate_interfaces(autoware_control_msgs
      msg/Control.msg msg/ControlHorizon.msg msg/Lateral.msg msg/Longitudinal.msg
      LANGUAGE CPP DEPENDENCIES std_msgs builtin_interfaces ${_nros_skip_install})
  nros_generate_interfaces(autoware_adapi_v1_msgs
      msg/OperationModeState.msg
      LANGUAGE CPP DEPENDENCIES builtin_interfaces std_msgs geometry_msgs
      ${_nros_skip_install})
  nros_generate_interfaces(tier4_debug_msgs
      msg/Float32MultiArrayStamped.msg msg/Float32Stamped.msg
      msg/Float64MultiArrayStamped.msg msg/Float64Stamped.msg
      msg/MultiArrayDimension.msg msg/MultiArrayLayout.msg
      msg/ProcessingTimeNode.msg msg/ProcessingTimeTree.msg
      LANGUAGE CPP DEPENDENCIES builtin_interfaces std_msgs ${_nros_skip_install})

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
