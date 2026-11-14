# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# A stock ROS 2 message package: nano-ros routes rosidl_generate_interfaces()
# to its own codegen, and `colcon build` builds it unchanged.
cmake_minimum_required(VERSION 3.20)
project(safety_island_msgs)

find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(builtin_interfaces REQUIRED)
find_package(autoware_control_msgs REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  msg/ApprovedRequest.msg
  DEPENDENCIES builtin_interfaces autoware_control_msgs
)

ament_export_dependencies(rosidl_default_runtime)
ament_package()
