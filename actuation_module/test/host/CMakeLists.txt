# Copyright (c) 2026, Arm Limited / NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Dependency-free host unit tests for the controller's pure decision logic
# (supervision latch, candidate identity, VP reference placement, input
# staleness, MPC trajectory-buffer policy) and the X5H OS-free cores
# (rpmsg netif core, si channel). None of them links a middleware, an RTOS or
# the controller, so they build with the host compiler alone:
#
#   cmake -S actuation_module/test/host -B build/host-tests
#   cmake --build build/host-tests && ctest --test-dir build/host-tests
#
# Upstream builds the same sources under the DDS freertos-posix lane's
# BUILD_TEST=1 selector; this branch retired that CMake tree with the DDS
# lanes, so the tests get a standalone project of their own.

cmake_minimum_required(VERSION 3.16)
project(asi_host_tests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(ACTUATION_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(FOLLOWER_INC ${ACTUATION_DIR}/src/autoware/autoware_trajectory_follower_node/include)
set(MPC_INC ${ACTUATION_DIR}/src/autoware/autoware_mpc_lateral_controller/include)
set(X5H_DIR ${ACTUATION_DIR}/freertos_x5h)

enable_testing()

function(asi_host_test name main inc)
  add_executable(${name} ${main} ${ARGN})
  target_include_directories(${name} PRIVATE ${inc})
  target_compile_options(${name} PRIVATE -Wall -Wextra)
  add_test(NAME ${name} COMMAND ${name})
endfunction()

asi_host_test(input_staleness_gate_test
  ${ACTUATION_DIR}/test/test_input_staleness_gate.cpp ${FOLLOWER_INC})
asi_host_test(trajectory_buffer_policy_test
  ${ACTUATION_DIR}/test/test_trajectory_buffer_policy.cpp ${MPC_INC})
asi_host_test(candidate_selection_test
  ${ACTUATION_DIR}/test/test_candidate_selection.cpp ${FOLLOWER_INC})
asi_host_test(supervision_latch_test
  ${ACTUATION_DIR}/test/test_supervision_latch.cpp ${FOLLOWER_INC})
asi_host_test(vp_reference_test
  ${ACTUATION_DIR}/test/test_vp_reference.cpp ${FOLLOWER_INC})
asi_host_test(rpmsg_netif_core_test
  ${ACTUATION_DIR}/test/test_rpmsg_netif_core.c ${X5H_DIR}
  ${X5H_DIR}/rpmsg_netif_core.c)
asi_host_test(si_channel_test
  ${ACTUATION_DIR}/test/test_si_channel.c ${X5H_DIR}
  ${X5H_DIR}/si_channel.c)
