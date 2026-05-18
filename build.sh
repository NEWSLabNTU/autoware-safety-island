#! /usr/bin/env bash

# Copyright (c) 2025-2026, Arm Limited / NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Build script for the Zephyr Actuation Module (nano-ros backed).

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ROOT_DIR=$(dirname "$(realpath "$0")")
set -e
set -u

BUILD_TEST_FLAG=0
BUILD_NANO_ROS_SMOKE=0
ZEPHYR_TARGET_LIST=("fvp_baser_aemv8r_smp" "s32z270dc2_rtu0_r52@D")
ZEPHYR_TARGET=${ZEPHYR_TARGET_LIST[0]}

function usage() {
  echo -e "${GREEN}Usage: $0 [OPTIONS]${NC}"
  echo -e "------------------------------------------------"
  echo -e "${GREEN}    -t                 ${NC}Zephyr target board: ${ZEPHYR_TARGET_LIST[*]}"
  echo -e "${GREEN}                         default: ${ZEPHYR_TARGET_LIST[0]} (FVP).${NC}"
  echo -e "${GREEN}    -c                 ${NC}Clean all builds and exit."
  echo -e "${GREEN}    -h                 ${NC}Display the usage and exit."
  echo ""
  echo -e "${GREEN}    Optional arguments to build Zephyr test programs:${NC}"
  echo -e "${GREEN}    --unit-test        ${NC}Build Zephyr unit test program."
  echo -e "${GREEN}    --dds-publisher    ${NC}Build Zephyr DDS publisher."
  echo -e "${GREEN}    --dds-subscriber   ${NC}Build Zephyr DDS subscriber."
  echo ""
  echo -e "${GREEN}    Phase 1 nano-ros smoke:${NC}"
  echo -e "${GREEN}    --nano-ros-smoke   ${NC}Build the nano-ros smoke Zephyr app"
  echo -e "${GREEN}                       ${NC}(actuation_module/nano_ros_smoke/)."
}

function parse_args() {
  new_args=()
  for arg in "$@"; do
    case $arg in
      --help)
        usage
        exit 0
        ;;
      --unit-test)
        BUILD_TEST_FLAG=1
        shift
        ;;
      --dds-publisher)
        BUILD_TEST_FLAG=2
        shift
        ;;
      --dds-subscriber)
        BUILD_TEST_FLAG=3
        shift
        ;;
      --nano-ros-smoke)
        BUILD_NANO_ROS_SMOKE=1
        shift
        ;;
      *)
        new_args+=("$arg")
        ;;
    esac
  done
  set -- "${new_args[@]}"

  while getopts "t:ch" opt; do
    case ${opt} in
      t )
        ZEPHYR_TARGET=""
        for t in "${ZEPHYR_TARGET_LIST[@]}"; do
          if [ "${t}" = "${OPTARG}" ]; then
            ZEPHYR_TARGET=${t}
            break
          fi
        done
        if [ -z "${ZEPHYR_TARGET}" ]; then
          echo -e "${RED}Invalid Zephyr target: ${OPTARG}${NC}\n" 1>&2
          echo -e "${YELLOW}Valid targets: ${ZEPHYR_TARGET_LIST[*]}${NC}" 1>&2
          exit 1
        fi
        ;;
      c )
        clean
        exit 0
        ;;
      h )
        usage
        exit 0
        ;;
      \? )
        echo -e "${RED}Invalid option: ${OPTARG}${NC}\n" 1>&2
        usage
        exit 1
        ;;
    esac
  done
  shift $((OPTIND -1))
}

function clean() {
  rm -rf "${ROOT_DIR}"/build "${ROOT_DIR}"/install
}

function require_nros_checkout() {
  if [ ! -d "${ROOT_DIR}"/modules/nros ]; then
    echo -e "${RED}nano-ros checkout missing at modules/nros.${NC}" 1>&2
    echo -e "${YELLOW}Run \`west update\` to fetch nano-ros from the manifest.${NC}" 1>&2
    exit 1
  fi
}

function build_actuation_module() {
  echo -e "${GREEN}Building Zephyr Actuation Module (nano-ros)...${NC}"
  require_nros_checkout

  # Idempotent bootstrap: builds nros-codegen + stages serdes +
  # templates + regen's nros-c cbindgen header. Skips work already done.
  bash "${ROOT_DIR}"/scripts/bootstrap-nano-ros-shim.sh

  typeset CMAKE_PREFIX_PATH=""
  typeset AMENT_PREFIX_PATH=""

  # Pass the resolved host path of nros-codegen to CMake.
  # `nano_ros_overlay.conf` hard-codes a container-relative
  # `CONFIG_NROS_CODEGEN_TOOL` for the legacy /autoware-safety-island
  # bind-mount layout, which fails when build.sh runs directly on the
  # host (fixuid devcontainer or no container at all). The
  # `_NANO_ROS_CODEGEN_TOOL` cache var is the documented override
  # (see modules/nros/zephyr/cmake/nros_generate_interfaces.cmake).
  local nros_codegen="${ROOT_DIR}/modules/nros/build/install/bin/nros-codegen"

  local build_args=(
    -DZEPHYR_TARGET="${ZEPHYR_TARGET}"
    -DEXTRA_CONF_FILE="${ROOT_DIR}"/actuation_module/nano_ros_overlay.conf
    -D_NANO_ROS_CODEGEN_TOOL="${nros_codegen}"
    -DEXTRA_CFLAGS="-Wno-error"
    -DEXTRA_CXXFLAGS="-Wno-error"
    -DBUILD_TEST=${BUILD_TEST_FLAG}
  )

  if [ "${ZEPHYR_TARGET}" = "s32z270dc2_rtu0_r52@D" ]; then
    build_args+=(-DEXTRA_DTC_OVERLAY_FILE="${ROOT_DIR}"/actuation_module/boards/s32z270dc2_rtu0_r52@D.overlay)
  fi

  west build -p auto -d build/actuation_module -b "${ZEPHYR_TARGET}" \
    actuation_module/ -- "${build_args[@]}"
}

function build_nano_ros_smoke() {
  echo -e "${GREEN}Building nano-ros smoke Zephyr app...${NC}"
  require_nros_checkout

  typeset CMAKE_PREFIX_PATH=""
  typeset AMENT_PREFIX_PATH=""

  local build_args=(
    -DEXTRA_CFLAGS="-Wno-error"
    -DEXTRA_CXXFLAGS="-Wno-error"
  )

  if [ "${ZEPHYR_TARGET}" = "s32z270dc2_rtu0_r52@D" ]; then
    build_args+=(-DEXTRA_DTC_OVERLAY_FILE="${ROOT_DIR}"/actuation_module/boards/s32z270dc2_rtu0_r52@D.overlay)
  fi

  west build -p auto -d build/nano_ros_smoke -b "${ZEPHYR_TARGET}" \
    actuation_module/nano_ros_smoke/ -- "${build_args[@]}"
}

## MAIN ##
parse_args "$@"

cd "${ROOT_DIR}"
mkdir -p build

if [ "${BUILD_NANO_ROS_SMOKE}" = "1" ]; then
  build_nano_ros_smoke
  exit 0
fi

build_actuation_module
