# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_universe_utils: vendored from Autoware, one package as upstream.
# Autoware's universe utilities, the geometry and math subset the controllers
# use (geometry, alt_geometry, pose_deviation, normalization, constants,
# stop_watch).

cmake_minimum_required(VERSION 3.22.1)

# Added once. A dependent's add_subdirectory() fallback may have added this
# package already: nano-ros's generated Zephyr root adds the image's
# packages in name order, not <depend> order.
if(TARGET autoware_universe_utils)
  return()
endif()
# The controller's images only. A workspace configure adds every package, so
# the test programs' images (src/test_bringup) configure this one too; there
# it would build a second controller program for nothing.
if(DEFINED NROS_BRINGUP_DIR AND NOT NROS_BRINGUP_DIR MATCHES "/controller_bringup/?$")
  return()
endif()
project(autoware_universe_utils LANGUAGES C CXX)

# The packages this one <depend>s on, added here when nobody did yet:
# nano-ros's metadata probe configures a node package without its <depend>
# closure, and its generated Zephyr root adds packages in name order.
if(NOT TARGET asi_common)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../asi_common" asi_common)
endif()
if(NOT TARGET Eigen3::Eigen)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../eigen" eigen)
endif()
# Upstream's spelling; src/eigen points it at the island's Eigen 3.4.0.
find_package(Eigen3 3.4 REQUIRED)

# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_universe_utils STATIC
  src/geometry/alt_geometry.cpp
  src/geometry/geometry.cpp
  src/geometry/pose_deviation.cpp
)
target_link_libraries(autoware_universe_utils PUBLIC
  asi_common
  Eigen3::Eigen
)
# The parameter API with std::string / std::vector<T> overloads the vendored
# code declares its parameters through; PUBLIC, so every package above has it.
target_compile_definitions(autoware_universe_utils PUBLIC NROS_CPP_STD=1)
# The vendored tree is C++17 (std::optional throughout). A floor, not a pin.
target_compile_features(autoware_universe_utils PUBLIC cxx_std_17)

# The two message packages of this workspace are configured before this one,
# so the verb finds them built and does not link them.
foreach(_msgpkg visionpilot_msgs safety_island_msgs)
  if(TARGET ${_msgpkg}::${_msgpkg})
    target_link_libraries(autoware_universe_utils PUBLIC ${_msgpkg}::${_msgpkg})
  endif()
endforeach()
