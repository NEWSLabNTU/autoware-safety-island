# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_motion_utils: vendored from Autoware, one package as upstream.
# Autoware's motion utilities, the trajectory subset the controllers use.

cmake_minimum_required(VERSION 3.22.1)

project(autoware_motion_utils LANGUAGES C CXX)

# Upstream's spelling; src/eigen points it at the island's Eigen 3.4.0.
find_package(Eigen3 3.4 REQUIRED)

# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_motion_utils STATIC
  src/trajectory/trajectory.cpp
)
target_link_libraries(autoware_motion_utils PUBLIC
  asi_common
  autoware_interpolation
  autoware_universe_utils
  Eigen3::Eigen
)
