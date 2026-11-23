# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_pid_longitudinal_controller: vendored from Autoware, one package as
# upstream. Autoware's PID longitudinal controller.

cmake_minimum_required(VERSION 3.22.1)

# The controller's images only. A workspace configure adds every package, so
# the test programs' images (src/test_bringup) configure this one too; there
# it would build a second controller program for nothing.
if(DEFINED NROS_BRINGUP_DIR AND NOT NROS_BRINGUP_DIR MATCHES "/controller_bringup/?$")
  return()
endif()
project(autoware_pid_longitudinal_controller LANGUAGES C CXX)

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
