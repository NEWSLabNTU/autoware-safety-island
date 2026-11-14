# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 4 W5.b — Entry pkg for the NXP S32Z270 RTU (Cortex-R52) FreeRTOS
# lane (nano-ros phase-372 board bundle).
#
# LAUNCH-only: the nros-board-s32z270-freertos board carries the startup
# (vector table + Reset + weak netif/tick hooks); the generated entry seeds
# the launch parameters and constructs controller_pkg::Controller as a
# FreeRTOS-task component over the cross-built CycloneDDS. DEPLOY names the
# [deploy.s32z2] block in controller_bringup/system.toml. The NXP-licensed
# glue (RTD NETC netif, CR52_GIC port) arrives via src/s32z2_board_glue +
# the FREERTOS_DIR/FREERTOS_PORT env seam when the SDK is provisioned;
# without it the image is LINK-COMPLETE against the bundle stubs.
cmake_minimum_required(VERSION 3.22.1)
project(freertos_s32z2_entry LANGUAGES C CXX)

nano_ros_add_executable(actuation_s32z2_entry
  BOARD   s32z270-freertos
  LANG    cpp
  BRINGUP "${CMAKE_CURRENT_SOURCE_DIR}/../controller_bringup"
  LAUNCH  default
  TYPED
  DEPLOY  s32z270-freertos)
