# Copyright (c) 2024-2025, Arm Limited.
# SPDX-License-Identifier: Apache-2.0

# PROJECT SETUP
cmake_minimum_required(VERSION 3.22.1)

# ---------------------------------------------------------------------------
# Phase 4 W5.a — FreeRTOS POSIX simulator lane (nano-ros workspace mode).
# Selected by -DNANO_ROS_PLATFORM=freertos (build.sh --platform freertos-posix).
# The same controller_pkg / controller_bringup / autoware_msgs sources build
# as a host process: the nros-board-freertos-posix board owns main() + the
# scheduler, nodes run as FreeRTOS tasks over host CycloneDDS (nano-ros
# phase-370). The Zephyr app below is untouched by this branch.
# ---------------------------------------------------------------------------
if(DEFINED NANO_ROS_PLATFORM AND NANO_ROS_PLATFORM STREQUAL "freertos")
  # Phase 4 W5.b — one workspace, one board per configure (the nano-ros
  # example-workspace contract). A cross board needs its CMAKE_TOOLCHAIN_FILE
  # set BEFORE project() (the first compiler probe); host-sim boards
  # (freertos-posix) need none.
  if(NOT DEFINED NANO_ROS_BOARD)
    set(NANO_ROS_BOARD freertos-posix)
  endif()
  # Every ARMv8-R cross board takes the same Cortex-R52 toolchain file: the
  # NXP S32Z270 (hardware) and QEMU's mps3-an536 (emulated, phase-6) differ in
  # what they can RUN, not in how they are compiled. Listed rather than
  # duplicated so a third R52 board is one entry, not a fourth copy of this
  # block.
  set(_asi_armv8r_boards "s32z270-freertos" "mps3-an536-freertos")
  set(_asi_is_armv8r FALSE)
  if(NANO_ROS_BOARD IN_LIST _asi_armv8r_boards)
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
  find_package(Eigen3 REQUIRED)
  find_package(nano_ros REQUIRED COMPONENTS workspace)
  if(NOT DEFINED NROS_RMW)
    set(NROS_RMW cyclonedds)
  endif()
  set(_asi_freertos_subdirs
      src/autoware/autoware_msgs
      src/controller_pkg)
  if(_asi_is_armv8r)
    # Cross target: no host rpath. Which entry leaf joins depends on the
    # board; the Eigen/pthread remedies below are shared by both because they
    # are properties of the arm-none-eabi ARMv8-R toolchain, not of the SoC.
    if(NANO_ROS_BOARD STREQUAL "s32z270-freertos")
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

    # Two hardware-proven remedies carried over from the legacy lane
    # (the retired legacy lane), both cross-only:
    #
    # (1) Eigen 3.4 psincos on arm-none-eabi ILP32: newlib types int32_t as
    #     `long`, so Eigen's NEON integer-packet specialisations (keyed on
    #     int32_t) never match psincos_float's plain-`int` scratch buffer —
    #     generic fallback fails to compile. Patch a COPY of the host Eigen
    #     at configure time (vendor_patched/eigen-psincos-int32.patch) and
    #     put it BEFORE the system tree.
    find_package(Patch REQUIRED)
    set(_eigen_patched_dir ${CMAKE_BINARY_DIR}/eigen-patched)
    set(_eigen_patch
        ${CMAKE_CURRENT_SOURCE_DIR}/src/s32z2_board_glue/vendor_patched/eigen-psincos-int32.patch)
    if(NOT EXISTS ${_eigen_patched_dir}/.patched)
      file(REMOVE_RECURSE ${_eigen_patched_dir})
      file(COPY ${EIGEN3_INCLUDE_DIR}/Eigen DESTINATION ${_eigen_patched_dir})
      execute_process(
        COMMAND ${Patch_EXECUTABLE} -p1 -d ${_eigen_patched_dir}
        INPUT_FILE ${_eigen_patch}
        RESULT_VARIABLE _eigen_patch_rc)
      if(NOT _eigen_patch_rc EQUAL 0)
        message(FATAL_ERROR
            "Failed to apply ${_eigen_patch} to Eigen at ${_eigen_patched_dir}")
      endif()
      file(WRITE ${_eigen_patched_dir}/.patched "")
    endif()
    include_directories(BEFORE ${_eigen_patched_dir})

    # (2) newlib's <pthread.h> declares types but implements nothing on
    #     arm-none-eabi; common/logger needs mutexes. The legacy lane's
    #     FreeRTOS-backed pthread shim (Apache, ASI-authored) shadows it.
    #     ONLY pthread.h — the legacy dir also carries a FreeRTOSConfig.h
    #     that must NOT shadow the board bundle's (it lacks the CRx port's
    #     tick/EOI seam), so the shim is staged alone.
    set(_asi_pthread_shim_dir ${CMAKE_BINARY_DIR}/s32z2-pthread-shim)
    file(MAKE_DIRECTORY ${_asi_pthread_shim_dir})
    configure_file(
        # Named for the board it was written for, but the gap it fills is
        # newlib's on arm-none-eabi — every ARMv8-R lane needs it.
        ${CMAKE_CURRENT_SOURCE_DIR}/include/platform/freertos/s32z2/pthread.h
        ${_asi_pthread_shim_dir}/pthread.h COPYONLY)
    include_directories(BEFORE ${_asi_pthread_shim_dir})

    # The shim's task-create switch: NXP's GCC/ARM_CR52_GIC port needs its
    # xTaskCreate*Fpu variants (lazy FPEXC re-enable finds the FP save area
    # via TLS[0]); the upstream GCC/ARM_CRx_No_GIC port has only the plain
    # creators. Key the shim on the provisioned port.
    if("${FREERTOS_PORT}$ENV{FREERTOS_PORT}" MATCHES "ARM_CR52_GIC")
      add_compile_definitions(ASI_S32Z2_NXP_PORT=1)
    endif()
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
    PLATFORM "${NANO_ROS_PLATFORM}"
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
  if("param_services" IN_LIST NANO_ROS_FEATURES)
    add_compile_definitions(NROS_SYSTEM_PARAM_SERVICES)
  endif()

  add_subdirectory(src/controller_pkg)

  # Phase 4 — canonical LAUNCH+BRINGUP spelling (nano-ros phase-330 W7):
  # the SystemModel is resolved at CONFIGURE time from the bringup's
  # system.toml + launch XML (`nros model-path`), replacing the committed
  # play_launch model (upstream rule: SystemModels are build artifacts,
  # never committed). Both entries — this Zephyr one and the
  # freertos_posix_entry pkg — now read the SAME authored bringup,
  # including the [tiers.control] RT model.
  nano_ros_entry(
    NAME    actuation_entry
    BOARD   zephyr
    BRINGUP "${CMAKE_CURRENT_SOURCE_DIR}/src/controller_bringup"
    LAUNCH  default
    TYPED
    DEPLOY  fvp)

  # The network-readiness prologue (previously in main.cpp) is now a STRONG
  # override of the weak `nros_board_network_wait()` hook the generated entry's
  # `ZephyrBoard::run_components` calls before `nros::init`. configure_network()
  # lives in network_config.cpp (compiled into app).
  target_sources(app PRIVATE
    src/common/net/network_config.cpp
    src/common/clock/clock_resync.cpp
    src/board_network_hook.cpp)
endif()

# Real-time evaluation Layer 1: the periodic statistics reporter. Self-
# registering via K_THREAD_DEFINE, so no entry point needs to call it and every
# image (controller and tests alike) reports identically.
if(CONFIG_ASI_THREAD_STATS_REPORT)
  target_sources(app PRIVATE src/common/diag/thread_stats_report.c)
endif()

# phase-8 W8 — the overwrite-oldest tracing backend. Independent of the stats
# reporter above; it registers itself with TRACING_BACKEND_DEFINE(), whose
# header lives in Zephyr's PRIVATE tracing include dir rather than the public
# tree, so the path has to be added by hand. There is no public header for
# defining a tracing backend out of tree.
if(CONFIG_ASI_TRACE_RING)
  target_sources(app PRIVATE src/common/diag/trace_ring_backend.c)
  target_include_directories(app PRIVATE ${ZEPHYR_BASE}/subsys/tracing/include)
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
