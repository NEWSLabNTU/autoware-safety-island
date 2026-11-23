# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_interpolation: vendored from Autoware, one package as upstream.
# Autoware's interpolation library (linear, spline, spherical linear, 2-D
# spline points).

cmake_minimum_required(VERSION 3.22.1)

project(autoware_interpolation LANGUAGES C CXX)

# Upstream's spelling; src/eigen points it at the island's Eigen 3.4.0.
find_package(Eigen3 3.4 REQUIRED)

# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_interpolation STATIC
  src/linear_interpolation.cpp
  src/spherical_linear_interpolation.cpp
  src/spline_interpolation.cpp
  src/spline_interpolation_points_2d.cpp
)
target_link_libraries(autoware_interpolation PUBLIC
  asi_common
  autoware_universe_utils
  Eigen3::Eigen
)
