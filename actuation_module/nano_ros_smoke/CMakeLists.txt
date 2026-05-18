# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 1A smoke — minimal nros-cpp Int32 publisher proving the nano-ros
# Zephyr module wires into the ASI build. Adapted from
# nano-ros-autoware/examples/zephyr/cpp/dds/talker/.

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(asi_nano_ros_smoke LANGUAGES CXX)

# Backend = dust-dds (CONFIG_NROS_RMW_DDS) — selected in prj.conf.
# Generated C++ bindings come from the nros module's codegen helper.
nros_generate_interfaces(std_msgs LANGUAGE CPP)

target_sources(app PRIVATE src/main.cpp)
