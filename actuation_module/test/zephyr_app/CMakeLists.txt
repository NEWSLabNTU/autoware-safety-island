# Copyright (c) 2024-2026, Arm Limited and NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# The Zephyr test programs, a west application of their own (nano-ros's
# "A Zephyr app you build with west"): each is a hand-written main() over the
# platform layer and nros-cpp, with no bringup image and no generated entry.
# build.sh builds one per run (--dds-publisher, --dds-subscriber,
# --can-output-test, --dds-loopback-test), naming it with -DASI_TEST. The unit
# test and the DDS loopback test are also images of their own on every board
# (src/test_bringup, `nros run`); the loopback test stays here for the
# real-time evaluation's statistics and trace builds.
#
# Its Kconfig settings are the controller images' own fragments
# (../../src/controller_bringup/zephyr/), so a test runs on the configuration
# the controller ships with; build.sh passes them, then this directory's
# fragments, as EXTRA_CONF_FILE.

cmake_minimum_required(VERSION 3.22.1)

get_filename_component(_asi_ws "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

set(_asi_tests dds_pub dds_sub can_output_test dds_loopback_test)
if(NOT ASI_TEST IN_LIST _asi_tests)
  message(FATAL_ERROR "test/zephyr_app: -DASI_TEST=<one of ${_asi_tests}>, got '${ASI_TEST}'")
endif()

set(CONF_FILE "${_asi_ws}/src/controller_bringup/zephyr/prj-actuation.conf")

# The board package's prj.conf, per-board conf and devicetree overlay, as the
# generated controller application gets them.
if(DEFINED ENV{NROS_REPO_DIR})
  set(_nros_repo "$ENV{NROS_REPO_DIR}")
else()
  get_filename_component(_nros_repo "${_asi_ws}/../modules/nros" ABSOLUTE)
endif()
include(${_nros_repo}/zephyr/cmake/nano_ros_use_board.cmake)
if(BOARD MATCHES "^s32z")
  nano_ros_use_board(s32z270-rtu0-zephyr)
else()
  nano_ros_use_board(fvp-aemv8r-smp)
endif()

# asi_common's Kconfig symbols (it is a Zephyr module).
list(APPEND ZEPHYR_EXTRA_MODULES "${_asi_ws}/src/asi_common")

# The capabilities the controller image declares (controller_bringup's
# features = ["param_services"], and a launch that seeds parameters), as
# Kconfig before find_package(Zephyr), where Kconfig runs. A guest
# application states them itself; the generated one gets them from the
# bringup.
set(CONFIG_NROS_CAPABILITY_PARAM_SERVICES y CACHE STRING "as controller_bringup" FORCE)
set(CONFIG_NROS_PARAMS_STORE y CACHE STRING "as controller_bringup" FORCE)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(asi_zephyr_tests)

# The two supervision message packages are workspace packages.
set(NROS_INTERFACE_SEARCH_PATH "${_asi_ws}/src")

add_subdirectory("${_asi_ws}/src/asi_common" asi_common)
target_link_libraries(app PRIVATE asi_common)

# The message set of asi_common's umbrella header. The tests use the
# idlc-style C headers (<pkg>/msg/<Name>.h) too, which the Zephyr module emits
# under cyclonedds-ts/_genroot.
nros_find_interfaces(
  PACKAGE_XML "${_asi_ws}/src/asi_common/package.xml"
  LANGUAGE CPP SKIP_INSTALL)
target_include_directories(app PRIVATE "${CMAKE_BINARY_DIR}/cyclonedds-ts/_genroot")

target_sources(app PRIVATE "${_asi_ws}/test/${ASI_TEST}.cpp")

# The DDS loopback and CAN output tests are also images (src/test_bringup),
# so their main() is the hosted signature nano-ros's ROS2_MAIN calls. Here,
# with no ROS2_MAIN, it is renamed and called from Zephyr's main(void), as
# ROS2_MAIN does.
if(ASI_TEST STREQUAL "dds_loopback_test" OR ASI_TEST STREQUAL "can_output_test")
  set_source_files_properties("${_asi_ws}/test/${ASI_TEST}.cpp"
    PROPERTIES COMPILE_DEFINITIONS "main=asi_hosted_main")
  target_sources(app PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/hosted_main.cpp")
endif()
