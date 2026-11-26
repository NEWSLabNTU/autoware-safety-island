# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# asi_common: the Safety Island's platform layer, shared by the controller and
# the Zephyr test programs. It carries what is specific to a platform or a
# toolchain, so that no node package has to name one:
#
#   asi_common   headers (common/, platform/, and the message umbrella
#                autoware/autoware_msgs/messages.hpp), the PLATFORM_* define
#                (read only by the clock and network headers and sources), the
#                newlib pthread shim on arm-none-eabi, and the support sources
#                of each platform
#                (Zephyr: network bring-up, the entry's network
#                hook, the Kconfig-gated diagnostics; bare-metal FreeRTOS:
#                the board wall-clock hook). The wall clock is nano-ros's on
#                every platform (phase-15 P5); on bare-metal FreeRTOS its
#                source is the island's SNTP task behind nano-ros's `board`
#                hook.
#
# Eigen is the `eigen` package's (src/eigen), not this one's.
#
# Everything is keyed off what the build already knows: a Zephyr build has
# `zephyr_interface`, a FreeRTOS build has NROS_PLATFORM=freertos, and the
# ARMv8-R cross toolchain sets CMAKE_SYSTEM_PROCESSOR=cortex-r52.

cmake_minimum_required(VERSION 3.22.1)
project(asi_common LANGUAGES C CXX)

set(_asi_zephyr FALSE)
set(_asi_newlib_cross FALSE)
if(TARGET zephyr_interface)
  set(_asi_zephyr TRUE)
elseif(NROS_PLATFORM STREQUAL "freertos")
  # Bare-metal FreeRTOS on a Cortex-R52 (mps3-an536, S32Z270): newlib, no
  # pthreads. The POSIX simulator is a host build.
  if(CMAKE_SYSTEM_PROCESSOR STREQUAL "cortex-r52")
    set(_asi_newlib_cross TRUE)
  endif()
endif()
# Anything else is a host configure (NROS_PLATFORM=posix): nano-ros's metadata
# probe, which compiles the controller's sources to count their entities, and
# the census's `linux` images, which build and run them once.

# --- asi_common: headers ------------------------------------------------------
add_library(asi_common INTERFACE)
target_include_directories(asi_common INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

# The logger's compile-time floor (common/logger/logger.hpp): nano-ros's
# RCLC_LOG_MIN_SEVERITY, 0 trace .. 6 none, numbered as the image's
# log.max_level. A log_* call below it, and PROFILE_*, compile to nothing.
# It is the image's log.max_level ([image.<id>] knobs.log.max_level), which
# nano-ros resolves and hands to C/C++: on Zephyr as Kconfig's
# CONFIG_NROS_LOG_MAX_LEVEL (autoconf.h), elsewhere as the compile definition
# NROS_LOG_MAX_LEVEL on NanoRos::NanoRos (nano-ros issue 2952). The floor
# names that symbol, so the island holds no level of its own.
if(_asi_zephyr)
  target_compile_definitions(asi_common INTERFACE
    RCLC_LOG_MIN_SEVERITY=CONFIG_NROS_LOG_MAX_LEVEL)
else()
  target_compile_definitions(asi_common INTERFACE
    RCLC_LOG_MIN_SEVERITY=NROS_LOG_MAX_LEVEL)
endif()

# The CAN control-command output (common/can/can_platform.hpp over nano-ros's
# <nros/platform_can.h>). On Zephyr it is the Kconfig symbol
# CONFIG_CONTROL_CMD_CAN_OUTPUT. Elsewhere it is always built: every board
# links a frame driver backend (SocketCAN on the host-stack boards, whose
# images name their device in [image.<id>.can]; nano-ros's weak fail-loud
# defaults on the other boards, whose open returns ENOTSUP; the census mock
# in a census or metadata-probe host build). The launch arg control_output
# says whether it is used.
if(NOT _asi_zephyr)
  target_compile_definitions(asi_common INTERFACE CONFIG_CONTROL_CMD_CAN_OUTPUT=1)
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
  # The FVP has no CAN controller: its CAN output is the island's UDP tunnel
  # (one 48-byte datagram per three-frame command), the strong
  # nros_platform_can_* symbols of this source. An object of `app`, as the
  # frame driver's board hook asks (RFC-0132 D3); CONFIG_CAN is off then, so
  # nano-ros's Zephyr backend is not linked beside it.
  if(CONFIG_CONTROL_CMD_CAN_TRANSPORT_UDP_TUNNEL)
    target_sources(app PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src/zephyr/can_udp_tunnel_driver.cpp")
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
  # nano-ros's `board` wall-clock hook (nros_board_wall_clock_ns), which the
  # bare-metal images' [knobs.clock] source = "board" asks for: the island's
  # SNTP task over lwIP. nano-ros ships no default, and the one reference is
  # in a nano-ros archive, so the hook must be an object of the image
  # (RFC-0141 D2's link rule): an object library whose objects ride
  # asi_common's interface onto every executable linking it. An image that
  # does not select `board` (the test programs) never calls it.
  add_library(asi_common_board_clock OBJECT
    "${CMAKE_CURRENT_SOURCE_DIR}/src/platform/freertos/board_wall_clock.cpp")
  # FreeRTOS and lwIP headers: the board's, carried by the nano-ros runtime a
  # C++ component links.
  nros_link_runtime_umbrella(asi_common_board_clock PRIVATE CANDIDATES NanoRos::NanoRosCpp)
  target_compile_features(asi_common_board_clock PRIVATE cxx_std_17)
  target_link_libraries(asi_common INTERFACE $<TARGET_OBJECTS:asi_common_board_clock>)
  add_dependencies(asi_common asi_common_board_clock)
endif()
