# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_pid_longitudinal_controller: vendored from Autoware, one package as
# upstream. Autoware's PID longitudinal controller.

cmake_minimum_required(VERSION 3.22.1)

# Added once. A dependent's add_subdirectory() fallback may have added this
# package already: nano-ros's generated Zephyr root adds the image's
# packages in name order, not <depend> order.
if(TARGET autoware_pid_longitudinal_controller)
  return()
endif()
# The controller's images only. A workspace configure adds every package, so
# the test programs' images (src/test_bringup) configure this one too; there
# it would build a second controller program for nothing.
if(DEFINED NROS_BRINGUP_DIR AND NOT NROS_BRINGUP_DIR MATCHES "/controller_bringup/?$")
  return()
endif()
project(autoware_pid_longitudinal_controller LANGUAGES C CXX)

# The packages this one <depend>s on, added here when nobody did yet:
# nano-ros's metadata probe configures a node package without its <depend>
# closure, and its generated Zephyr root adds packages in name order.
if(NOT TARGET asi_common)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../asi_common" asi_common)
endif()
if(NOT TARGET Eigen3::Eigen)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../eigen" eigen)
endif()
if(NOT TARGET autoware_interpolation)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../autoware_interpolation" autoware_interpolation)
endif()
if(NOT TARGET autoware_motion_utils)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../autoware_motion_utils" autoware_motion_utils)
endif()
if(NOT TARGET autoware_trajectory_follower_base)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../autoware_trajectory_follower_base" autoware_trajectory_follower_base)
endif()
if(NOT TARGET autoware_universe_utils)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../autoware_universe_utils" autoware_universe_utils)
endif()
if(NOT TARGET autoware_vehicle_info_utils)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../autoware_vehicle_info_utils" autoware_vehicle_info_utils)
endif()
# Upstream's spelling; src/eigen points it at the island's Eigen 3.4.0.
find_package(Eigen3 3.4 REQUIRED)

# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_pid_longitudinal_controller STATIC
  src/longitudinal_controller_utils.cpp
  src/pid.cpp
  src/pid_longitudinal_controller.cpp
  src/smooth_stop.cpp
)
target_link_libraries(autoware_pid_longitudinal_controller PUBLIC
  asi_common
  autoware_interpolation
  autoware_motion_utils
  autoware_trajectory_follower_base
  autoware_universe_utils
  autoware_vehicle_info_utils
  Eigen3::Eigen
)
