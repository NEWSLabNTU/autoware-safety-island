# Copyright (c) 2024-2025, Arm Limited.
# SPDX-License-Identifier: Apache-2.0

# PROJECT SETUP
cmake_minimum_required(VERSION 3.22.1)

# Every controller image (Zephyr and FreeRTOS) is built by `nros build
# <image>` (build.sh), which generates its application. This file is the
# hand-written Zephyr application of the test programs only (BUILD_TEST 1-5).
if(DEFINED NROS_PLATFORM AND NROS_PLATFORM STREQUAL "freertos")
  message(FATAL_ERROR
    "actuation_module: FreeRTOS images are built by `nros build <image>` "
    "(build.sh --platform freertos-*), not by this CMakeLists.txt.")
endif()
if(NOT DEFINED BUILD_TEST OR BUILD_TEST STREQUAL "0")
  message(FATAL_ERROR
    "actuation_module: the controller images are built by `nros build <image>` "
    "(build.sh --platform zephyr-*); this application builds a test program "
    "(-DBUILD_TEST=1..5).")
endif()

# The controller images' application settings, so a test runs on the
# configuration the controller ships with.
set(CONF_FILE "${CMAKE_CURRENT_SOURCE_DIR}/src/controller_bringup/zephyr/prj-actuation.conf")

# Phase 2.C / 215.B — board glue is ONE line. `nano_ros_use_board()` layers the
# fvp-aemv8r-smp board crate's BOARD / per-board prj.conf / DTS overlay / default
# RMW (cyclonedds) / runner (armfvp) into this build. It MUST run BEFORE
# find_package(Zephyr) so those cache vars land in time for Zephyr's
# board-resolution phase (the fn FATAL_ERRORs otherwise). Replaces the
# hand-glued EXTRA_CONF_FILE / DTC_OVERLAY / BOARD wiring.
if(DEFINED ENV{NROS_REPO_DIR})
  set(_nros_repo "$ENV{NROS_REPO_DIR}")
else()
  # ASI consumes nano-ros as a west module checked out at <repo>/modules/nros.
  get_filename_component(_nros_repo "${CMAKE_CURRENT_SOURCE_DIR}/../modules/nros" ABSOLUTE)
endif()
include(${_nros_repo}/zephyr/cmake/nano_ros_use_board.cmake)
# Two Zephyr targets, two board packages. The FVP is nano-ros's
# fvp-aemv8r-smp. The S32Z270 RTU0 R52 (-t s32z270dc2_rtu0_r52@D, release
# only) has no nano-ros Zephyr board, so this workspace carries one
# (src/s32z270_zephyr_board); NROS_EXTRA_BOARD_PATH is how nano_ros_use_board
# finds a board outside the nano-ros tree.
if(BOARD MATCHES "^s32z270dc2_rtu0_r52")
  # build.sh exports NROS_EXTRA_BOARD_PATH for this target: the nros CLI calls
  # of this configure that do not run on this workspace (the board projection
  # here, on the nano-ros tree; the board-facts check, on the bringup dir) find
  # the package through it. Calls on this workspace find the package anyway;
  # nano-ros counts it once (nano-ros PR 3709).
  nano_ros_use_board(s32z270-rtu0-zephyr)
else()
  nano_ros_use_board(fvp-aemv8r-smp)
endif()

# The bringup's capabilities as Kconfig, set before find_package(Zephyr) where
# Kconfig runs -- what `nros build` writes into the west application it
# generates (nano-ros issues 1702/1706, builder/west_app.rs). This app is
# hand-written, so it states them itself: controller_bringup declares
# features = ["param_services"] and its launch file seeds parameters, which
# implies the parameter store. Without these the runtime is built with neither,
# and the nros heap default does not account for the store.
set(CONFIG_NROS_CAPABILITY_PARAM_SERVICES y CACHE STRING "declared by controller_bringup" FORCE)
set(CONFIG_NROS_PARAM_STORE y CACHE STRING "controller_bringup's launch seeds parameters" FORCE)

# The application's Kconfig symbols are asi_common's (src/asi_common/zephyr/
# Kconfig): the package is a Zephyr module, which `nros build` adds to the
# west application it generates for an image that depends on it. This
# hand-written application names it itself.
list(APPEND ZEPHYR_EXTRA_MODULES "${CMAKE_CURRENT_SOURCE_DIR}/src/asi_common")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(actuation_module)
include(GNUInstallDirs)


### MESSAGES ###
# controller_pkg's package.xml <depend>s name the message packages; nano-ros
# generates them (nano_ros_auto_add_library in the controller build, the call
# below in the test builds). The two supervision packages are in src/, which
# the resolver searches through NROS_INTERFACE_SEARCH_PATH.
set(NROS_INTERFACE_SEARCH_PATH "${CMAKE_CURRENT_SOURCE_DIR}/src")

### PLATFORM LAYER ###
# src/asi_common: headers, PLATFORM_ZEPHYR, Eigen, and the Zephyr support
# sources (network bring-up, SNTP resync, the entry's network hook, the
# Kconfig-gated diagnostics). A test image has no generated entry to hook.
set(ASI_COMMON_ENTRY_HOOK OFF CACHE BOOL "" FORCE)
add_subdirectory(src/asi_common)
target_link_libraries(app PRIVATE asi_common asi_eigen)

### BUILD ACTUATION MODULE ###

# Build Type
# Test programs use the idlc-style C headers/types (SteeringReport.h,
# autoware_vehicle_msgs_msg_SteeringReport) so the CAN/DDS tests stay
# middleware-independent. Since the eace28852 pin the Zephyr module emits
# those compat headers under cyclonedds-ts/_genroot/<pkg>/msg/ and keeps
# that root PRIVATE to the per-package descriptor libs — expose it to the
# test sources (includes are spelled <pkg>/msg/<Name>.h).
target_include_directories(app PRIVATE
  "${CMAKE_BINARY_DIR}/cyclonedds-ts/_genroot")

# The test programs use the message set of asi_common's umbrella header,
# with no controller in the image. The Zephyr module provides the verb;
# find_package(nano_ros) would resolve an image, which a test is not.
nros_find_interfaces(
  PACKAGE_XML "${CMAKE_CURRENT_SOURCE_DIR}/src/asi_common/package.xml"
  LANGUAGE CPP SKIP_INSTALL)

if(BUILD_TEST STREQUAL "1")
  target_sources(app PRIVATE test/unit_test.cpp)
elseif(BUILD_TEST STREQUAL "2")
  target_sources(app PRIVATE test/dds_pub.cpp)
elseif(BUILD_TEST STREQUAL "3")
  target_sources(app PRIVATE test/dds_sub.cpp)
elseif(BUILD_TEST STREQUAL "4")
  target_sources(app PRIVATE test/can_output_test.cpp)
elseif(BUILD_TEST STREQUAL "5")
  target_sources(app PRIVATE test/dds_loopback_test.cpp)
endif()
