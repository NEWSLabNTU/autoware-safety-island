# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# eigen: the island's own Eigen 3.4.0 (header-only), a package of this
# workspace. nano-ros ships no general-purpose C++ library (nano-ros #4013);
# a package finds and links one of its own the way it would without nano-ros.
# So consumers write upstream's spelling,
#
#   find_package(Eigen3 REQUIRED)
#   target_link_libraries(<t> PUBLIC Eigen3::Eigen)
#
# and Eigen3_DIR, set here, points that find at cmake/Eigen3Config.cmake,
# never at a host Eigen. Every package of an image configures in one CMake
# run, so a package that <depend>s on `eigen` is configured after this one.
# The board's toolchain decides what builds; the headers are the same for
# every target, with the arm-none-eabi fix (patches/) already applied.

cmake_minimum_required(VERSION 3.22.1)
project(eigen LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/Eigen3Config.cmake")
set(Eigen3_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake" CACHE PATH
  "the island's Eigen 3.4.0 (src/eigen)" FORCE)

# `eigen::eigen` for a sibling's find_package(eigen), where the ament verbs
# exist (a nano-ros workspace build).
if(COMMAND ament_package)
  ament_package()
endif()
