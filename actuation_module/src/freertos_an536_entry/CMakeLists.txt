# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 6 A3 — Entry pkg for the EMULATED Cortex-R52 lane (QEMU mps3-an536,
# nano-ros phase-385 board bundle).
#
# Deliberately identical in shape to src/freertos_s32z2_entry: same CPU, same
# kernel port, same bringup, same TYPED LAUNCH entry. The only differences are
# the board name and what the board can do — this one BOOTS, so the ARMv8-R
# code path the S32Z2 lane can only link gets runtime coverage in CI with no
# hardware and no NXP SDK.
#
# DEPLOY names the [deploy.an536] block in controller_bringup/system.toml; the
# board bundle carries the startup (EL2->EL1 drop, GICv3, generic-timer tick)
# and the LAN9118 netif, so nothing licensed or consumer-provided is involved.
cmake_minimum_required(VERSION 3.22.1)
project(freertos_an536_entry LANGUAGES C CXX)

nano_ros_add_executable(actuation_an536_entry
  BOARD   mps3-an536-freertos
  LANG    cpp
  BRINGUP "${CMAKE_CURRENT_SOURCE_DIR}/../controller_bringup"
  LAUNCH  default
  TYPED
  DEPLOY  mps3-an536-freertos)
