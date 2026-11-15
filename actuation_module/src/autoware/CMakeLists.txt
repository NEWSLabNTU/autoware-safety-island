# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# autoware_controller_libs: the vendored Autoware controllers (MPC lateral +
# PID longitudinal), their base classes and the utility libraries they need,
# built as one library package. Each component keeps its upstream directory
# and include/ tree. The node class (autoware_trajectory_follower_node) is
# controller_pkg's: it is the node, and it reads controller_pkg's identity.
#
# Not vendored into the build: autoware_osqp_interface (the MPC uses the
# unconstrained fast QP solver) and autoware_msgs/msg/*.idl (the upstream
# freertos_x5h build's input).

cmake_minimum_required(VERSION 3.22.1)
project(autoware_controller_libs LANGUAGES C CXX)

# The platform layer (logger, clock, platform defines, Eigen). Configured
# before this package in a workspace build; added here when this package is
# configured on its own (nano-ros's metadata probe).
if(NOT TARGET asi_common)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../asi_common" asi_common)
endif()

# A library, not a node: nano_ros_auto_add_library() generates the message
# packages package.xml <depend>s on, links them and the nros-cpp runtime the
# sources include, and gives it the Zephyr compile context.
nano_ros_auto_add_library(autoware_controller_libs STATIC
  autoware_universe_utils/src/geometry/geometry.cpp
  autoware_universe_utils/src/geometry/alt_geometry.cpp
  autoware_universe_utils/src/geometry/pose_deviation.cpp
  autoware_interpolation/src/linear_interpolation.cpp
  autoware_interpolation/src/spline_interpolation.cpp
  autoware_interpolation/src/spline_interpolation_points_2d.cpp
  autoware_interpolation/src/spherical_linear_interpolation.cpp
  autoware_motion_utils/src/trajectory/trajectory.cpp
  autoware_vehicle_info_utils/src/vehicle_info_utils.cpp
  autoware_vehicle_info_utils/src/vehicle_info.cpp
  autoware_trajectory_follower_base/src/lateral_controller_base.cpp
  autoware_trajectory_follower_base/src/longitudinal_controller_base.cpp
  autoware_mpc_lateral_controller/src/mpc_lateral_controller.cpp
  autoware_mpc_lateral_controller/src/mpc.cpp
  autoware_mpc_lateral_controller/src/mpc_trajectory.cpp
  autoware_mpc_lateral_controller/src/mpc_utils.cpp
  autoware_mpc_lateral_controller/src/steering_predictor.cpp
  autoware_mpc_lateral_controller/src/lowpass_filter.cpp
  autoware_mpc_lateral_controller/src/qp_solver/qp_solver_unconstraint_fast.cpp
  autoware_mpc_lateral_controller/src/steering_offset/steering_offset.cpp
  autoware_mpc_lateral_controller/src/vehicle_model/vehicle_model_bicycle_dynamics.cpp
  autoware_mpc_lateral_controller/src/vehicle_model/vehicle_model_bicycle_kinematics.cpp
  autoware_mpc_lateral_controller/src/vehicle_model/vehicle_model_bicycle_kinematics_no_delay.cpp
  autoware_mpc_lateral_controller/src/vehicle_model/vehicle_model_interface.cpp
  autoware_pid_longitudinal_controller/src/pid.cpp
  autoware_pid_longitudinal_controller/src/smooth_stop.cpp
  autoware_pid_longitudinal_controller/src/longitudinal_controller_utils.cpp
  autoware_pid_longitudinal_controller/src/pid_longitudinal_controller.cpp
)

target_include_directories(autoware_controller_libs PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_universe_utils/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_interpolation/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_motion_utils/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_vehicle_info_utils/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_trajectory_follower_base/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_mpc_lateral_controller/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/autoware_pid_longitudinal_controller/include"
)
target_link_libraries(autoware_controller_libs PUBLIC asi_common asi_eigen)
# The parameter API with std::string / std::vector<T> overloads the MPC and
# PID controllers declare their parameters through.
target_compile_definitions(autoware_controller_libs PUBLIC NROS_CPP_STD=1)
# The vendored tree is C++17 (std::optional throughout). A floor, not a pin.
target_compile_features(autoware_controller_libs PUBLIC cxx_std_17)

# The two message packages of this workspace are configured before this one,
# so the verb finds them built and does not link them.
foreach(_msgpkg visionpilot_msgs safety_island_msgs)
  if(TARGET ${_msgpkg}::${_msgpkg})
    target_link_libraries(autoware_controller_libs PUBLIC ${_msgpkg}::${_msgpkg})
  endif()
endforeach()

