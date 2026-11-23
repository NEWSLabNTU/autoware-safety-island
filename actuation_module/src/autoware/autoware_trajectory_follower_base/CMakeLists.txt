# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_trajectory_follower_base: vendored from Autoware, one package as
# upstream. The trajectory follower's controller base classes (lateral and
# longitudinal), their input data and the control horizon.

cmake_minimum_required(VERSION 3.22.1)

# The controller's images only. A workspace configure adds every package, so
# the test programs' images (src/test_bringup) configure this one too; there
# it would build a second controller program for nothing.
if(DEFINED NROS_BRINGUP_DIR AND NOT NROS_BRINGUP_DIR MATCHES "/controller_bringup/?$")
  return()
endif()
project(autoware_trajectory_follower_base LANGUAGES C CXX)

# Upstream's spelling; src/eigen points it at the island's Eigen 3.4.0.
find_package(Eigen3 3.4 REQUIRED)

# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_trajectory_follower_base STATIC
  src/lateral_controller_base.cpp
  src/longitudinal_controller_base.cpp
)
target_link_libraries(autoware_trajectory_follower_base PUBLIC
  asi_common
  autoware_interpolation
  autoware_motion_utils
  autoware_universe_utils
  autoware_vehicle_info_utils
  Eigen3::Eigen
)
