# Copyright (c) 2024-2025, Arm Limited.
# SPDX-License-Identifier: Apache-2.0

# PROJECT SETUP
cmake_minimum_required(VERSION 3.22.1)

# ---------------------------------------------------------------------------
# Phase 4 W5.a — FreeRTOS POSIX simulator lane (nano-ros workspace mode).
# Selected by -DNROS_PLATFORM=freertos (build.sh --platform freertos-posix).
# The same controller_pkg / controller_bringup / autoware_msgs sources build
# as a host process: the nros-board-freertos-posix board owns main() + the
# scheduler, nodes run as FreeRTOS tasks over host CycloneDDS (nano-ros
# phase-370). The Zephyr app below is untouched by this branch.
# ---------------------------------------------------------------------------
if(DEFINED NROS_PLATFORM AND NROS_PLATFORM STREQUAL "freertos")
  # Phase 4 W5.b — one workspace, one board per configure (the nano-ros
  # example-workspace contract). A cross board needs its CMAKE_TOOLCHAIN_FILE
  # set BEFORE project() (the first compiler probe); host-sim boards
  # (freertos-posix) need none.
  if(NOT DEFINED NROS_BOARD)
    set(NROS_BOARD freertos-posix)
  endif()
  # Every ARMv8-R cross board takes the same Cortex-R52 toolchain file: the
  # NXP S32Z270 (hardware) and QEMU's mps3-an536 (emulated, phase-6) differ in
  # what they can RUN, not in how they are compiled. Listed rather than
  # duplicated so a third R52 board is one entry, not a fourth copy of this
  # block.
  set(_asi_armv8r_boards "s32z270-freertos" "mps3-an536-freertos")
  set(_asi_is_armv8r FALSE)
  if(NROS_BOARD IN_LIST _asi_armv8r_boards)
    set(_asi_is_armv8r TRUE)
  endif()
  if(NOT CMAKE_TOOLCHAIN_FILE AND _asi_is_armv8r)
    if(DEFINED ENV{NROS_REPO_DIR})
      set(_asi_nros_root "$ENV{NROS_REPO_DIR}")
    else()
      get_filename_component(_asi_nros_root
          "${CMAKE_CURRENT_SOURCE_DIR}/../modules/nros" ABSOLUTE)
    endif()
    set(CMAKE_TOOLCHAIN_FILE
        "${_asi_nros_root}/cmake/toolchain/arm-freertos-armcr52.cmake")
  endif()

  project(actuation_module_freertos LANGUAGES C CXX)
  find_package(nano_ros REQUIRED COMPONENTS workspace)
  if(NOT DEFINED NROS_RMW)
    set(NROS_RMW cyclonedds)
  endif()
  set(_asi_freertos_subdirs
      src/asi_common
      src/visionpilot_msgs
      src/safety_island_msgs
      src/controller_pkg)
  if(_asi_is_armv8r)
    # Cross target: no host rpath. Which entry leaf joins depends on the
    # board.
    if(NROS_BOARD STREQUAL "s32z270-freertos")
      # The NXP-licensed board glue (RTD NETC netif override etc.) joins only
      # when its SDK env is provisioned — the pkg's own CMakeLists gates and
      # reports.
      list(APPEND _asi_freertos_subdirs
          src/s32z2_board_glue
          src/freertos_s32z2_entry)
    else()
      # phase-6 A3 — the emulated lane needs no board glue at all: the
      # nano-ros mps3-an536 bundle carries startup, GICv3, tick and netif.
      list(APPEND _asi_freertos_subdirs
          src/freertos_an536_entry)
    endif()
    # The Eigen patch and the newlib pthread shim this cross toolchain needs
    # come from src/asi_common.
  else()
    # The self-provisioned CycloneDDS builds shared libddsc into <build>/lib;
    # bake the run path so the entry runs without LD_LIBRARY_PATH.
    set(CMAKE_BUILD_RPATH "${CMAKE_BINARY_DIR}/lib")
    list(APPEND _asi_freertos_subdirs src/freertos_posix_entry)
  endif()

  nano_ros_workspace(
    ORDER_FROM_DEPENDS
    # SYSTEM resolves the bringup's capability axes ([system].features —
    # param_services for launch-param seeding) BEFORE the runtime import
    # (nano-ros issue 0353 rule; without it no capability reaches the build).
    SYSTEM   controller_bringup
    BACKEND  ${NROS_RMW}
    PLATFORM "${NROS_PLATFORM}"
    SUBDIRS  ${_asi_freertos_subdirs})
  return()
endif()

set(CONF_FILE "prj_actuation.conf")

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
if(NOT BUILD_TEST STREQUAL "0")
  set(ASI_COMMON_ENTRY_HOOK OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory(src/asi_common)
target_link_libraries(app PRIVATE asi_common asi_eigen)

### BUILD ACTUATION MODULE ###
set(APP_SOURCES "" CACHE INTERNAL "Global source files list")
set(APP_INCLUDE_DIRS "" CACHE INTERNAL "Global include directories list")

# Build Type
# Test programs use the idlc-style C headers/types (SteeringReport.h,
# autoware_vehicle_msgs_msg_SteeringReport) so the CAN/DDS tests stay
# middleware-independent. Since the eace28852 pin the Zephyr module emits
# those compat headers under cyclonedds-ts/_genroot/<pkg>/msg/ and keeps
# that root PRIVATE to the per-package descriptor libs — expose it to the
# test sources (includes are spelled <pkg>/msg/<Name>.h).
if(NOT BUILD_TEST STREQUAL "0")
  target_include_directories(app PRIVATE
    "${CMAKE_BINARY_DIR}/cyclonedds-ts/_genroot")
endif()

if(NOT BUILD_TEST STREQUAL "0")
  # The test programs use the controller's message set and its umbrella
  # header, with no controller in the image. The Zephyr module provides the
  # verb; find_package(nano_ros) would resolve an image, which a test is not.
  nros_find_interfaces(
    PACKAGE_XML "${CMAKE_CURRENT_SOURCE_DIR}/src/controller_pkg/package.xml"
    LANGUAGE CPP SKIP_INSTALL)
  target_include_directories(app PRIVATE src/controller_pkg/include)
endif()

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
else()
  # Phase 2.C / 242.5 — workspace mode. The controller is the nano-ros Node pkg
  # `controller_pkg` (its OWN project()); `nano_ros_node_register(... TYPED SHAPE
  # rclcpp DEPLOY zephyr)` inside it builds the component lib from the controller
  # + the 8 vendored autoware libs and generates the bootable `int main()` Zephyr
  # entry directly into `app`. This SUPERSEDES the pre-2.C monolithic
  # AUTOWARE_COMPONENTS-into-`app` foreach + the imperative `src/main.cpp` boot
  # (both removed) — topology is now declarative (controller_bringup/) and the
  # entry is generated, not hand-written.
  # Phase 3 W2.b — canonical RFC-0048 shape: the verbs come from
  # find_package(nano_ros) (287-W6 supplies them on Zephyr without
  # re-importing the runtime), the node pkg registers a carrier-less
  # component, and the LAUNCH-only entry below assembles the bootable
  # image from controller_bringup's launch topology.
  find_package(nano_ros REQUIRED HINTS "${NROS_REPO_DIR}")
  # On Zephyr, find_package(nano_ros) sets NROS_DEPLOY / NROS_LEAF_IMAGE_ID
  # from the APP dir's own system.toml. This app has none (its images are
  # rows in src/controller_bringup/system.toml), so both come back empty and
  # shadow build.sh's -DNROS_DEPLOY=fvp; `nros ws board-facts` then sees four
  # images and refuses as ambiguous (nano-ros 05b7f7d). Name ours again.
  if(DEFINED CACHE{NROS_DEPLOY} AND NOT "$CACHE{NROS_DEPLOY}" STREQUAL "")
    set(NROS_DEPLOY "$CACHE{NROS_DEPLOY}")
  else()
    set(NROS_DEPLOY fvp)
  endif()
  set(NROS_LEAF_IMAGE_ID "${NROS_DEPLOY}")

  # Phase 6 W6 — lower the param_services capability into OUR scope before the
  # node package is added.
  #
  # modules/nros/zephyr/CMakeLists.txt already does
  # `add_compile_definitions(NROS_SYSTEM_PARAM_SERVICES)` under the same
  # condition, but add_compile_definitions() is DIRECTORY-SCOPED: it applies to
  # the nros Zephyr module's own directory and never reaches
  # src/controller_pkg. The component therefore compiled with
  # ComponentNode::adopt_launch_seed_() #if'd out, so declare_parameter()
  # never consulted the executor's launch-seeded store and every launch
  # parameter silently lost to its compiled default.
  #
  # MEASURED: `ctrl_period` is seeded 0.03 by the generated entry and the
  # control loop ran at 151 ms — the 0.15 s default — a 5x slower control loop
  # than declared. Probe at construction: `adopted=0.150000 has_param=1`.
  #
  # nano_ros_workspace(SYSTEM ...) lowers the axes from a scope that parents
  # the component directories, which is why the freertos-posix lane was
  # unaffected; the Zephyr lane's mirror sits in the wrong directory. Upstream
  # names the follow-up ("resolve from the entry's BRINGUP like
  # nano_ros_workspace(SYSTEM ...) does") — until that lands, lower it here.
  if("param_services" IN_LIST NROS_FEATURES)
    add_compile_definitions(NROS_SYSTEM_PARAM_SERVICES)
  endif()

  add_subdirectory(src/controller_pkg)

  # Phase 4 — canonical LAUNCH+BRINGUP spelling (nano-ros phase-330 W7):
  # the SystemModel is resolved at CONFIGURE time from the bringup's
  # system.toml + launch XML (`nros model-path`), replacing the committed
  # play_launch model (upstream rule: SystemModels are build artifacts,
  # never committed). Both entries — this Zephyr one and the
  # freertos_posix_entry pkg — now read the SAME authored bringup,
  # including the [tasks.control] RT model.
  nano_ros_entry(
    NAME    actuation_entry
    BOARD   zephyr
    BRINGUP "${CMAKE_CURRENT_SOURCE_DIR}/src/controller_bringup"
    LAUNCH  default
    TYPED
    DEPLOY  ${NROS_DEPLOY})
endif()

message("=== Build Summary ===")
message("App sources: ${APP_SOURCES}")
message("App headers: ${APP_INCLUDE_DIRS}")

# TODO: Eigen fine tuning settings for possible memory alignment issues
# target_compile_definitions(app PRIVATE
#   EIGEN_DONT_VECTORIZE
#   EIGEN_DISABLE_UNALIGNED_ARRAY_ASSERT
#   # EIGEN_MAX_ALIGN_BYTES=0
#   EIGEN_DONT_ALIGN
#   EIGEN_DONT_ALIGN_STATICALLY
# )

# nros-cpp + generated message headers + linkage are wired into `app`
# automatically by the nano-ros Zephyr module (CONFIG_NROS_CPP_API=y).
target_include_directories(app PRIVATE ${APP_INCLUDE_DIRS})
