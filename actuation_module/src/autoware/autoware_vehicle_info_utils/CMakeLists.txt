# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_vehicle_info_utils: vendored from Autoware, one package as
# upstream. Autoware's vehicle info utilities: the vehicle parameters read
# from node parameters.

cmake_minimum_required(VERSION 3.22.1)

# Added once. A dependent's add_subdirectory() fallback may have added this
# package already: nano-ros's generated Zephyr root adds the image's
# packages in name order, not <depend> order.
if(TARGET autoware_vehicle_info_utils)
  return()
endif()
project(autoware_vehicle_info_utils LANGUAGES C CXX)

# The packages this one <depend>s on, added here when nobody did yet:
# nano-ros's metadata probe configures a node package without its <depend>
# closure, and its generated Zephyr root adds packages in name order.
if(NOT TARGET asi_common)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../asi_common" asi_common)
endif()
if(NOT TARGET autoware_universe_utils)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../autoware_universe_utils" autoware_universe_utils)
endif()

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
