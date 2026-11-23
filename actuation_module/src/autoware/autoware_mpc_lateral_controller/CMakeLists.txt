# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_mpc_lateral_controller: vendored from Autoware, one package as
# upstream. Autoware's MPC lateral controller, with the unconstrained fast QP
# solver.

cmake_minimum_required(VERSION 3.22.1)

# The controller's images only. A workspace configure adds every package, so
# the test programs' images (src/test_bringup) configure this one too; there
# it would build a second controller program for nothing.
if(DEFINED NROS_BRINGUP_DIR AND NOT NROS_BRINGUP_DIR MATCHES "/controller_bringup/?$")
  return()
endif()
project(autoware_mpc_lateral_controller LANGUAGES C CXX)

# Upstream's spelling; src/eigen points it at the island's Eigen 3.4.0.
find_package(Eigen3 3.4 REQUIRED)

# nano_ros_auto_add_library() generates the message packages package.xml
# <depend>s on, links them and the nros-cpp runtime, adds include/ and gives
# the library the Zephyr compile context.
nano_ros_auto_add_library(autoware_mpc_lateral_controller STATIC
  src/lowpass_filter.cpp
  src/mpc.cpp
  src/mpc_lateral_controller.cpp
  src/mpc_trajectory.cpp
  src/mpc_utils.cpp
  src/qp_solver/qp_solver_unconstraint_fast.cpp
  src/steering_offset/steering_offset.cpp
  src/steering_predictor.cpp
  src/vehicle_model/vehicle_model_bicycle_dynamics.cpp
  src/vehicle_model/vehicle_model_bicycle_kinematics.cpp
  src/vehicle_model/vehicle_model_bicycle_kinematics_no_delay.cpp
  src/vehicle_model/vehicle_model_interface.cpp
)
target_link_libraries(autoware_mpc_lateral_controller PUBLIC
  asi_common
  autoware_interpolation
  autoware_motion_utils
  autoware_trajectory_follower_base
  autoware_universe_utils
  autoware_vehicle_info_utils
  Eigen3::Eigen
)
