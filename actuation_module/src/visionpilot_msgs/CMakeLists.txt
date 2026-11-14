# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# A stock ROS 2 message package: nano-ros routes rosidl_generate_interfaces()
# to its own codegen, and `colcon build` builds it unchanged.
cmake_minimum_required(VERSION 3.20)
project(visionpilot_msgs)

find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(builtin_interfaces REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  msg/DrivingCommand.msg
  msg/DrivingReference.msg
  DEPENDENCIES builtin_interfaces
)

ament_export_dependencies(rosidl_default_runtime)
ament_package()
