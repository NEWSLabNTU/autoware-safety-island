# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# find_package(Eigen3) for the island's Eigen 3.4.0 (see ../CMakeLists.txt):
# upstream's target and variables, over this package's include/eigen3.

get_filename_component(_asi_eigen_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT TARGET Eigen3::Eigen)
  add_library(Eigen3::Eigen INTERFACE IMPORTED GLOBAL)
  set_target_properties(Eigen3::Eigen PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_asi_eigen_root}/include/eigen3")
endif()
set(Eigen3_FOUND TRUE)
set(EIGEN3_FOUND TRUE)
set(EIGEN3_INCLUDE_DIR "${_asi_eigen_root}/include/eigen3")
set(EIGEN3_INCLUDE_DIRS "${EIGEN3_INCLUDE_DIR}")
set(EIGEN3_VERSION_STRING "3.4.0")
unset(_asi_eigen_root)
