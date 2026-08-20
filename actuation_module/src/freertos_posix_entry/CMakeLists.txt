# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 4 W5.a — Entry pkg for the FreeRTOS POSIX simulator lane.
#
# LAUNCH-only: the nros-board-freertos-posix board carries `int main()`
# (scheduler start + app task); the generated entry here seeds the launch
# parameters and constructs `controller_pkg::Controller` as a FreeRTOS-task
# component over host CycloneDDS. DEPLOY names the `[deploy.freertos-posix]`
# block in controller_bringup/system.toml.
cmake_minimum_required(VERSION 3.22.1)
project(freertos_posix_entry LANGUAGES C CXX)

nano_ros_add_executable(actuation_posix_entry
  BOARD   freertos-posix
  BRINGUP "${CMAKE_CURRENT_SOURCE_DIR}/../controller_bringup"
  LAUNCH  default
  TYPED
  DEPLOY  freertos-posix)
