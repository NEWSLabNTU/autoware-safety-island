# Copyright (c) 2024-2025, Arm Limited.
# SPDX-License-Identifier: Apache-2.0

# PROJECT SETUP
cmake_minimum_required(VERSION 3.22.1)
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
nano_ros_use_board(fvp-aemv8r-smp)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
if(BUILD_TEST STREQUAL "4" OR BUILD_TEST STREQUAL "5")
  set(EIGEN3_INCLUDE_DIR "")
else()
  find_package(Eigen3 REQUIRED)
endif()
project(actuation_module)
include(GNUInstallDirs)
set(PLATFORM_ZEPHYR ON)
# Phase 3 W1 — select the nros side of the dual-mode messages.hpp umbrella
# (the FreeRTOS platforms build without this define and take the idlc side).
add_compile_definitions(ASI_USE_NANO_ROS=1)
target_compile_definitions(app PRIVATE PLATFORM_ZEPHYR=1)

# nano-ros nros-cpp is the sole build path post-Phase 1.3/1.4 cleanup.
# Cross-package FFI staticlibs (autoware_msgs/<pkg>/nano_ros_cpp_ffi_*)
# include!() each other's per-message Rust shims to keep types in one
# scope, which means the same `nros_cpp_publish_*` / `_deserialize_*`
# symbols end up emitted in every downstream FFI staticlib that depends
# on a given package. The symbol bodies are byte-identical (codegen
# output), so let the linker drop the duplicates.
zephyr_ld_options(-Wl,--allow-multiple-definition)

### BUILD AUTOWARE MESSAGES ###
add_subdirectory(src/autoware/autoware_msgs)

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
  add_subdirectory(src/controller_pkg)

  # Phase 3 W4.3 (nano-ros phase-296) — canonical-path pilot: the entry
  # bakes from the play_launch-RESOLVED SystemModel (committed artifact,
  # `play_launch resolve launch/system.launch.xml --system system.toml`)
  # instead of re-parsing the launch XML. LAUNCH remains the transitional
  # fallback; regenerate the model after editing launch/system.toml.
  nano_ros_add_executable(actuation_entry
    BOARD   zephyr
    MODEL   "${CMAKE_CURRENT_SOURCE_DIR}/src/controller_bringup/config/system_model.yaml"
    TYPED)

  # The network-readiness prologue (previously in main.cpp) is now a STRONG
  # override of the weak `nros_board_network_wait()` hook the generated entry's
  # `ZephyrBoard::run_components` calls before `nros::init`. configure_network()
  # lives in network_config.cpp (compiled into app).
  target_sources(app PRIVATE
    src/common/net/network_config.cpp
    src/board_network_hook.cpp)
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

if(ZEPHYR_TARGET STREQUAL "fvp_baser_aemv8r_smp")
# NOTE: we dont have fabsl in zephyr for fvp builds, so we provide a substitute
target_compile_options(app PRIVATE 
  "-Dfabsl(x)=((long double)fabs((double)(x)))"
)
endif()

# nros-cpp + generated message headers + linkage are wired into `app`
# automatically by the nano-ros Zephyr module (CONFIG_NROS_CPP_API=y).
# autoware_msgs/CMakeLists.txt invokes nros_generate_interfaces() per
# vendored package; generated artefacts attach to `app` directly.
target_include_directories(app PRIVATE
    include
    ${EIGEN3_INCLUDE_DIR}
    ${APP_INCLUDE_DIRS}
)
# autoware_msgs INTERFACE target (no compiled sources) only exposes
# ASI's hand-written `<autoware/autoware_msgs/messages.hpp>` umbrella
# via INTERFACE_INCLUDE_DIRECTORIES. Link it so app gets that include
# path automatically.
target_link_libraries(app PRIVATE autoware_msgs)
