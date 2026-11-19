# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# asi_unit_test: the test program actuation_module/test/unit_test.cpp as a nano-ros
# image. It is the entry of the images of test_bringup/unit_test (`entry =
# "asi_unit_test"`), so `nros build` builds this package instead of generating
# one, and `nros run unit_test_bringup:<board> --expect ...` runs it. On a board
# the executable below is the image.
#
# The message set (package.xml) is asi_common's umbrella header's.

cmake_minimum_required(VERSION 3.22.1)
project(asi_unit_test LANGUAGES C CXX)

# A workspace configure adds every package, so this one is configured for
# the controller's images too; it builds a program only for its own.
if(DEFINED NROS_BRINGUP_DIR AND NOT NROS_BRINGUP_DIR MATCHES "/test_bringup/unit_test/?$")
  return()
endif()

get_filename_component(_ACT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)

# A workspace build has nano-ros loaded already; the census (a host build of
# this package alone, which sizes the image) does not.
if(NOT COMMAND nano_ros_add_executable)
  find_package(nano_ros REQUIRED)
endif()
if(NOT TARGET asi_common)
  add_subdirectory("${_ACT_ROOT}/src/asi_common" asi_common)
endif()

# ROS2_MAIN: the program keeps its own main(); on a board nano-ros renames it
# and calls it from the board's entry, with hosted C++. The interface packages
# package.xml names are generated and linked by the verb.
nano_ros_add_executable(asi_unit_test "${_ACT_ROOT}/test/unit_test.cpp" ROS2_MAIN)
target_link_libraries(asi_unit_test PRIVATE asi_common)
target_compile_features(asi_unit_test PRIVATE cxx_std_17)
