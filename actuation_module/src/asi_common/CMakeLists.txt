# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# asi_common: the Safety Island's platform layer, shared by the controller and
# the Zephyr test programs. It carries what is specific to a platform or a
# toolchain, so that no node package has to name one:
#
#   asi_common   headers (common/, platform/, and the message umbrella
#                autoware/autoware_msgs/messages.hpp), the PLATFORM_* define, the
#                FreeRTOS CONFIG_* mirror header, the newlib pthread shim on
#                arm-none-eabi, and the support sources of each platform
#                (Zephyr: network bring-up, SNTP resync, the entry's network
#                hook, the Kconfig-gated diagnostics; bare-metal FreeRTOS: the
#                wall clock).
#
# Eigen is the `eigen` package's (src/eigen), not this one's.
#
# Everything is keyed off what the build already knows: a Zephyr build has
# `zephyr_interface`, a FreeRTOS build has NROS_PLATFORM=freertos, and the
# ARMv8-R cross toolchain sets CMAKE_SYSTEM_PROCESSOR=cortex-r52.

cmake_minimum_required(VERSION 3.22.1)
project(asi_common LANGUAGES C CXX)

set(_asi_zephyr FALSE)
set(_asi_freertos FALSE)
set(_asi_newlib_cross FALSE)
if(TARGET zephyr_interface)
  set(_asi_zephyr TRUE)
elseif(NROS_PLATFORM STREQUAL "freertos")
  set(_asi_freertos TRUE)
  # Bare-metal FreeRTOS on a Cortex-R52 (mps3-an536, S32Z270): newlib, no
  # pthreads, no wall clock. The POSIX simulator is a host build.
  if(CMAKE_SYSTEM_PROCESSOR STREQUAL "cortex-r52")
    set(_asi_newlib_cross TRUE)
  endif()
else()
  # A host configure (NROS_PLATFORM=posix): nano-ros's metadata probe, which
  # compiles the controller's sources to count their entities. The headers
  # take the FreeRTOS road there, as they did before this package existed.
  set(_asi_freertos TRUE)
endif()

# --- asi_common: headers + platform defines ---------------------------------
add_library(asi_common INTERFACE)
target_include_directories(asi_common INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

if(_asi_zephyr)
  target_compile_definitions(asi_common INTERFACE PLATFORM_ZEPHYR=1)
else()
  target_compile_definitions(asi_common INTERFACE PLATFORM_FREERTOS=1)
  # platform_config.h reads a Kconfig-mirror header on FreeRTOS: the
  # controller's FreeRTOS logger, network and CAN defaults (the CAN output is
  # built in, so the mock CAN path stays exercised).
  set(CONFIG_LOG_LEVEL 1)
  set(CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX 0)
  set(CONFIG_ENABLE_SNTP OFF)
  set(CONFIG_CONTROL_CMD_CAN_OUTPUT 1)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/include/platform/freertos/freertos_config_generated.h.in"
    "${CMAKE_CURRENT_BINARY_DIR}/generated/freertos_config_generated.h")
  target_include_directories(asi_common INTERFACE
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
    "${CMAKE_CURRENT_SOURCE_DIR}/include/platform/freertos")
endif()

if(_asi_newlib_cross)
  # newlib's <pthread.h> declares the types but implements nothing on
  # arm-none-eabi, and common/logger needs mutexes. The FreeRTOS-backed shim
  # shadows it, staged into a directory of its own so that nothing else
  # lands ahead of the system headers.
  set(_asi_pthread_dir "${CMAKE_CURRENT_BINARY_DIR}/newlib-pthread-shim")
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/include/platform/freertos/s32z2/pthread.h"
    "${_asi_pthread_dir}/pthread.h" COPYONLY)
  target_include_directories(asi_common BEFORE INTERFACE "${_asi_pthread_dir}")
  # The shim's task-create switch: NXP's GCC/ARM_CR52_GIC port needs its
  # xTaskCreate*Fpu variants; the upstream GCC/ARM_CRx_No_GIC port has only
  # the plain creators. The port is a provisioning fact (FREERTOS_PORT).
  if("${FREERTOS_PORT}$ENV{FREERTOS_PORT}" MATCHES "ARM_CR52_GIC")
    target_compile_definitions(asi_common INTERFACE ASI_S32Z2_NXP_PORT=1)
  endif()
endif()

# --- Support sources ---------------------------------------------------------
if(_asi_zephyr)
  # Compiled into `app`: the one Zephyr target an application's code can link
  # into the image (a zephyr_library() declared after find_package(Zephyr) is
  # not), and where the strong nros_board_network_wait() below overrides the
  # generated entry's weak one.
  option(ASI_COMMON_ENTRY_HOOK
    "the network hook a generated controller entry calls before nros::init" ON)
  target_sources(app PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/common/net/network_config.cpp")
  if(ASI_COMMON_ENTRY_HOOK)
    target_sources(app PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src/common/clock/clock_resync.cpp"
      "${CMAKE_CURRENT_SOURCE_DIR}/src/zephyr/board_network_hook.cpp")
  endif()
  # Real-time evaluation Layer 1: the periodic statistics reporter,
  # self-registering through K_THREAD_DEFINE.
  if(CONFIG_ASI_THREAD_STATS_REPORT)
    target_sources(app PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src/common/diag/thread_stats_report.c")
  endif()
  # The overwrite-oldest tracing backend. TRACING_BACKEND_DEFINE() lives in
  # Zephyr's private tracing include directory; there is no public header for
  # an out-of-tree backend.
  if(CONFIG_ASI_TRACE_RING)
    target_sources(app PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src/common/diag/trace_ring_backend.c")
    target_include_directories(app PRIVATE ${ZEPHYR_BASE}/subsys/tracing/include)
  endif()
  target_link_libraries(app PRIVATE asi_common)
elseif(_asi_newlib_cross)
  # No wall clock on bare-metal FreeRTOS: nano-ros reports none and newlib's
  # _gettimeofday answers garbage, so every stamped command would be garbage.
  # This supplies one (SNTP epoch + the monotonic platform clock). The POSIX
  # simulator has the host clock.
  add_library(asi_common_freertos STATIC src/platform/freertos/wall_clock.cpp)
  target_link_libraries(asi_common_freertos PUBLIC asi_common)
  # FreeRTOS and lwIP headers: the board's, carried by the nano-ros runtime
  # a C++ component links.
  nros_link_runtime_umbrella(asi_common_freertos PUBLIC CANDIDATES NanoRos::NanoRosCpp)
  target_compile_features(asi_common_freertos PUBLIC cxx_std_17)
  target_link_libraries(asi_common INTERFACE asi_common_freertos)
  target_compile_definitions(asi_common INTERFACE ASI_FREERTOS_WALL_CLOCK=1)
endif()
