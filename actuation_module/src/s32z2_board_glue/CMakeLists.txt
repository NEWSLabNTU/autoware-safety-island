# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 4 W5.b — NXP-licensed S32Z270 board glue for the nano-ros lane.
#
# GATED on the NXP SDK environment (`S32_RTD_PATH` + the S32CT PBcfg set):
# the RTD NETC driver, its post-build configs and the CR52_GIC kernel port
# are NXP Confidential and are provisioned locally, never committed. Without
# the SDK this package contributes NOTHING and says so — the image still
# LINK-COMPLETES against the board bundle's weak fail-loud netif/tick stubs
# (the phase-372 W3 seam), which is the pre-hardware acceptance.
#
# With the SDK provisioned, this package compiles:
#   * src/s32z2_netif_glue.c — the STRONG `nros_board_register_netif` /
#     `nros_board_poll_netif` overrides,
#   * the hardware-proven legacy glue it delegates to
#     (`../../freertos_s32z2/lwip_bringup.c`, `ethif_shim.c`) plus the RTD
#     driver sources + PBcfg — the exact set the legacy lane's CMake proved
#     on the board. Wiring that set into this target is the FIRST task of
#     the hardware bring-up session (phase-4 W5.b item 5): it needs the SDK
#     present to iterate against, so it is deliberately not blind-authored
#     here. The seam and the delegation contract are done; the source list
#     is not.
cmake_minimum_required(VERSION 3.22.1)
project(s32z2_board_glue LANGUAGES C)

if(NOT DEFINED ENV{S32_RTD_PATH})
    message(STATUS
        "s32z2_board_glue: S32_RTD_PATH not set — NXP RTD glue SKIPPED. The "
        "image links against the board bundle's weak netif/tick stubs "
        "(boot will say 'no netif'). Provision the NXP SDK (see "
        "actuation_module/freertos_s32z2/README.md) to enable the NETC path.")
    return()
endif()

message(FATAL_ERROR
    "s32z2_board_glue: S32_RTD_PATH is set, but the RTD source wiring for "
    "the nano-ros lane lands with the hardware bring-up session (phase-4 "
    "W5.b item 5). Until then build without S32_RTD_PATH for the "
    "link-complete image, or use --platform freertos-s32z2-legacy for the "
    "proven legacy lane.")
