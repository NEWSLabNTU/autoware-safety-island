# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_vehicle_info_utils: vendored from Autoware, one package as
# upstream. Autoware's vehicle info utilities: the vehicle parameters read
# from node parameters.

cmake_minimum_required(VERSION 3.22.1)

project(autoware_vehicle_info_utils LANGUAGES C CXX)


# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_vehicle_info_utils STATIC
  src/vehicle_info.cpp
  src/vehicle_info_utils.cpp
)
target_link_libraries(autoware_vehicle_info_utils PUBLIC
  asi_common
  autoware_universe_utils
)
