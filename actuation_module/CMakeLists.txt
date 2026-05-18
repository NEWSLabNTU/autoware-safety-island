# Copyright (c) 2024-2025, Arm Limited.
# SPDX-License-Identifier: Apache-2.0

# PROJECT SETUP
cmake_minimum_required(VERSION 3.22.1)
set(CONF_FILE "prj_actuation.conf")
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

# Phase 1 migration toggle. OFF (default) = legacy raw-Cyclone path:
# Cyclone host tools + cdds_lib + idlc-generated autoware_msgs +
# common/dds/* wrapper. ON = nano-ros shim path: nros-cpp library
# (linked by the nros Zephyr module under CONFIG_NROS=y) +
# nros_generate_interfaces-generated autoware_msgs + common/node/
# node_nros.hpp shim + common/net/network_config.cpp.
option(ASI_USE_NANO_ROS "Use the nano-ros nros-cpp shim path instead of raw Cyclone DDS" OFF)

if(ASI_USE_NANO_ROS)
    target_compile_definitions(app PRIVATE ASI_USE_NANO_ROS=1)
    message(STATUS "ASI build mode: nano-ros shim (ASI_USE_NANO_ROS=ON)")
else()
    ### BUILD CYCLONEDDS LIBRARY ###
    message("Building cyclonedds for ${ZEPHYR_TARGET}")
    include(cyclonedds_config.cmake)
    create_cdds_lib(${CMAKE_CURRENT_SOURCE_DIR}/../cyclonedds)
endif()

### BUILD AUTOWARE MESSAGES ###
add_subdirectory(src/autoware/autoware_msgs)

### BUILD ACTUATION MODULE ###
set(APP_SOURCES "" CACHE INTERNAL "Global source files list")
set(APP_INCLUDE_DIRS "" CACHE INTERNAL "Global include directories list")

# Build Type
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
  set(AUTOWARE_COMPONENTS
    autoware_universe_utils
    autoware_interpolation
    autoware_motion_utils
    autoware_vehicle_info_utils
    autoware_trajectory_follower_base
    autoware_mpc_lateral_controller
    autoware_pid_longitudinal_controller
    autoware_trajectory_follower_node
  )

  foreach(component IN LISTS AUTOWARE_COMPONENTS)
    include(src/autoware/${component}/${component}.cmake)
  endforeach()

  if(ASI_USE_NANO_ROS)
    target_sources(app PRIVATE src/main.cpp src/common/net/network_config.cpp ${APP_SOURCES})
  else()
    target_sources(app PRIVATE src/main.cpp src/common/dds/network_config.cpp ${APP_SOURCES})
  endif()
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

if(ASI_USE_NANO_ROS)
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
else()
    target_include_directories(app PRIVATE
        include
        ${CMAKE_CURRENT_BINARY_DIR}/install/include
        ${CycloneDDS_INCLUDE_DIR}
        ${EIGEN3_INCLUDE_DIR}
        ${APP_INCLUDE_DIRS}
    )

    # Link actuation messages and CycloneDDS library
    target_link_directories(app PUBLIC ${CMAKE_CURRENT_BINARY_DIR}/install/lib)
    target_link_libraries(app PRIVATE cdds_lib autoware_msgs)
endif()
