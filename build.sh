#! /usr/bin/env bash

# Copyright (c) 2025, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
#
# Build script for supported Autoware Safety Island runtime targets.
#
# This script builds Zephyr and FreeRTOS runtime targets.
#
# Usage: ./build.sh [OPTIONS]

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Root directory
ROOT_DIR=$(dirname "$(realpath "$0")")
set -e
set -u
CYCLONEDDS_HOST_BUILD_DIR=${CYCLONEDDS_HOST_BUILD_DIR:-"${ROOT_DIR}/build/cyclonedds_host"}
CYCLONEDDS_HOST_PREFIX=${CYCLONEDDS_HOST_PREFIX:-"${CYCLONEDDS_HOST_BUILD_DIR}/out"}
CYCLONEDDS_TARGET_BUILD_DIR=${CYCLONEDDS_TARGET_BUILD_DIR:-"${ROOT_DIR}/build/cyclonedds_target"}
CYCLONEDDS_TARGET_PREFIX=${CYCLONEDDS_TARGET_PREFIX:-"${ROOT_DIR}/build/cyclonedds_target_out"}

# Build options
BUILD_TEST_FLAG=0
BUILD_DIR="build/actuation_module"
BUILD_DIR_SET=0
BUILD_PLATFORM="zephyr-fvp"
BUILD_PLATFORM_SET=0
NETWORK_PROFILE="default"
DDS_NETWORK_INTERFACE=""
CONTROL_CMD_OUTPUT_MODE=""
RUNTIME_TARGET_LIST=("zephyr-fvp" "zephyr-s32z" "freertos-posix" "freertos-s32z2")
ZEPHYR_TARGET_LIST=("fvp_baser_aemv8r_smp" "s32z270dc2_rtu0_r52@D")
ZEPHYR_TARGET=${ZEPHYR_TARGET_LIST[0]} # Default target is fvp_baser_aemv8r_smp
ZEPHYR_TARGET_SET=0

function usage() {
  echo -e "${GREEN}Usage: $0 [OPTIONS]${NC}"
  echo -e "------------------------------------------------"
  echo -e "${GREEN}    --platform         ${NC}Runtime target: ${RUNTIME_TARGET_LIST[*]}."
  echo -e "${GREEN}                         default: zephyr-fvp.${NC}"
  echo -e "${GREEN}    --network          ${NC}Network profile: default, tap. tap is valid for zephyr-fvp."
  echo -e "${GREEN}    --dds-interface    ${NC}DDS interface/IP selector for FreeRTOS targets."
  echo -e "${GREEN}    --control-output   ${NC}FreeRTOS control output: DDS_ONLY, CAN_ONLY, DDS_AND_CAN."
  echo -e "${GREEN}    -t                 ${NC}Zephyr target board: ${ZEPHYR_TARGET_LIST[*]}"
  echo -e "${GREEN}                         default: ${ZEPHYR_TARGET_LIST[0]}.${NC}"
  echo -e "${GREEN}    -d                 ${NC}Build directory. Default: ${BUILD_DIR}."
  echo -e "${GREEN}    -c                 ${NC}Clean all builds and exit."
  echo -e "${GREEN}    -h                 ${NC}Display the usage and exit."
  echo ""
  echo -e "${GREEN}    Optional arguments to build test programs:${NC}"
  echo -e "${GREEN}    --unit-test        ${NC}Build unit test program."
  echo -e "${GREEN}    --dds-publisher    ${NC}Build DDS publisher test program."
  echo -e "${GREEN}    --dds-subscriber   ${NC}Build DDS subscriber test program."
  echo -e "${GREEN}    --can-output-test  ${NC}Build CAN output test program."
  echo -e "${GREEN}    --dds-loopback-test${NC}Build Zephyr DDS loopback test program."
  echo ""
  echo -e "${GREEN}    Runtime target matrix:${NC}"
  echo -e "    zephyr-fvp       Zephyr on Arm FVP for local validation / AVH."
  echo -e "    zephyr-s32z      Zephyr on S32Z hardware."
  echo -e "    freertos-posix   FreeRTOS POSIX runtime for local validation."
  echo -e "    freertos-s32z2   FreeRTOS on S32Z2 hardware."
  echo ""
  echo -e "${GREEN}    Examples:${NC}"
  echo -e "    $0 --platform zephyr-fvp --network tap -d build/zephyr-fvp-tap"
  echo -e "    $0 --platform freertos-posix -d build/freertos-posix --dds-interface wlp2s0 --control-output DDS_ONLY"
  echo -e "    $0 --platform freertos-s32z2 -d build/freertos-s32z2 --dds-interface 192.168.0.105"
}

function require_arg() {
  local option="$1"
  local value="${2:-}"
  if [ -z "${value}" ]; then
    echo -e "${RED}${option} requires an argument${NC}" 1>&2
    exit 1
  fi
}

function validate_zephyr_target() {
  local target="$1"
  for t in "${ZEPHYR_TARGET_LIST[@]}"; do
    if [ "${t}" = "${target}" ]; then
      return 0
    fi
  done

  echo -e "${RED}Invalid Zephyr target: ${target}${NC}\n" 1>&2
  echo -e "${YELLOW}Valid targets: ${ZEPHYR_TARGET_LIST[*]}${NC}" 1>&2
  exit 1
}

function parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --platform)
        require_arg "$1" "${2:-}"
        BUILD_PLATFORM="$2"
        BUILD_PLATFORM_SET=1
        shift 2
        ;;
      --network)
        require_arg "$1" "${2:-}"
        NETWORK_PROFILE="$2"
        shift 2
        ;;
      --dds-interface)
        require_arg "$1" "${2:-}"
        DDS_NETWORK_INTERFACE="$2"
        shift 2
        ;;
      --control-output)
        require_arg "$1" "${2:-}"
        CONTROL_CMD_OUTPUT_MODE="$2"
        shift 2
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
      --can-output-test)
        BUILD_TEST_FLAG=4
        shift
        ;;
      --dds-loopback-test)
        BUILD_TEST_FLAG=5
        shift
        ;;
      -t)
        require_arg "$1" "${2:-}"
        validate_zephyr_target "$2"
        ZEPHYR_TARGET="$2"
        ZEPHYR_TARGET_SET=1
        shift 2
        ;;
      -d)
        require_arg "$1" "${2:-}"
        BUILD_DIR="$2"
        BUILD_DIR_SET=1
        shift 2
        ;;
      -c)
        clean
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option: $1${NC}\n" 1>&2
        usage
        exit 1
        ;;
    esac
  done
}

function normalize_platform() {
  if [ "${BUILD_PLATFORM_SET}" = "0" ] && [ "${ZEPHYR_TARGET_SET}" = "1" ]; then
    if [ "${ZEPHYR_TARGET}" = "fvp_baser_aemv8r_smp" ]; then
      BUILD_PLATFORM="zephyr-fvp"
    elif [ "${ZEPHYR_TARGET}" = "s32z270dc2_rtu0_r52@D" ]; then
      BUILD_PLATFORM="zephyr-s32z"
    fi
  fi

  case "${BUILD_PLATFORM}" in
    zephyr-fvp)
      if [ "${ZEPHYR_TARGET_SET}" = "1" ] && [ "${ZEPHYR_TARGET}" != "fvp_baser_aemv8r_smp" ]; then
        echo -e "${RED}--platform zephyr-fvp conflicts with -t ${ZEPHYR_TARGET}${NC}" 1>&2
        exit 1
      fi
      ZEPHYR_TARGET="fvp_baser_aemv8r_smp"
      if [ "${BUILD_DIR_SET}" = "0" ]; then
        BUILD_DIR="build/zephyr-fvp"
      fi
      ;;
    zephyr-s32z)
      if [ "${ZEPHYR_TARGET_SET}" = "1" ] && [ "${ZEPHYR_TARGET}" != "s32z270dc2_rtu0_r52@D" ]; then
        echo -e "${RED}--platform zephyr-s32z conflicts with -t ${ZEPHYR_TARGET}${NC}" 1>&2
        exit 1
      fi
      ZEPHYR_TARGET="s32z270dc2_rtu0_r52@D"
      if [ "${BUILD_DIR_SET}" = "0" ]; then
        BUILD_DIR="build/zephyr-s32z"
      fi
      ;;
    freertos-posix)
      if [ "${ZEPHYR_TARGET_SET}" = "1" ]; then
        echo -e "${RED}-t is only valid for Zephyr platforms${NC}" 1>&2
        exit 1
      fi
      if [ "${BUILD_DIR_SET}" = "0" ]; then
        BUILD_DIR="build/freertos-posix"
      fi
      ;;
    freertos-s32z2)
      if [ "${ZEPHYR_TARGET_SET}" = "1" ]; then
        echo -e "${RED}-t is only valid for Zephyr platforms${NC}" 1>&2
        exit 1
      fi
      if [ "${BUILD_DIR_SET}" = "0" ]; then
        BUILD_DIR="build/freertos-s32z2"
      fi
      ;;
    *)
      echo -e "${RED}Invalid platform: ${BUILD_PLATFORM}${NC}" 1>&2
      echo -e "${YELLOW}Valid platforms: ${RUNTIME_TARGET_LIST[*]}${NC}" 1>&2
      exit 1
      ;;
  esac

  if [ "${NETWORK_PROFILE}" != "default" ] && [ "${NETWORK_PROFILE}" != "tap" ]; then
    echo -e "${RED}Invalid network profile: ${NETWORK_PROFILE}${NC}" 1>&2
    echo -e "${YELLOW}Valid network profiles: default tap${NC}" 1>&2
    exit 1
  fi

  if [ "${NETWORK_PROFILE}" = "tap" ] && [ "${BUILD_PLATFORM}" != "zephyr-fvp" ]; then
    echo -e "${RED}--network tap is only valid for --platform zephyr-fvp${NC}" 1>&2
    exit 1
  fi

  if [ -n "${DDS_NETWORK_INTERFACE}" ] && [ "${BUILD_PLATFORM}" != "freertos-posix" ] && [ "${BUILD_PLATFORM}" != "freertos-s32z2" ]; then
    echo -e "${RED}--dds-interface is only valid for FreeRTOS platforms${NC}" 1>&2
    exit 1
  fi

  if [ -n "${CONTROL_CMD_OUTPUT_MODE}" ] && [ "${BUILD_PLATFORM}" != "freertos-posix" ] && [ "${BUILD_PLATFORM}" != "freertos-s32z2" ]; then
    echo -e "${RED}--control-output is only valid for FreeRTOS platforms${NC}" 1>&2
    exit 1
  fi

  if [ -n "${CONTROL_CMD_OUTPUT_MODE}" ]; then
    case "${CONTROL_CMD_OUTPUT_MODE}" in
      DDS_ONLY|CAN_ONLY|DDS_AND_CAN) ;;
      *)
        echo -e "${RED}Invalid control output mode: ${CONTROL_CMD_OUTPUT_MODE}${NC}" 1>&2
        echo -e "${YELLOW}Valid modes: DDS_ONLY CAN_ONLY DDS_AND_CAN${NC}" 1>&2
        exit 1
        ;;
    esac
  fi

  if [ "${BUILD_PLATFORM}" = "freertos-s32z2" ] && [ "${BUILD_TEST_FLAG}" != "0" ]; then
    echo -e "${RED}Test build options are not supported for --platform freertos-s32z2${NC}" 1>&2
    exit 1
  fi
}

function clean() {
  rm -rf "${ROOT_DIR}"/build "${ROOT_DIR}"/install
}

function build_cyclonedds_host() {
  if [ -x "${CYCLONEDDS_HOST_PREFIX}/bin/idlc" ]; then
    echo -e "${GREEN}CycloneDDS host tools already built at ${CYCLONEDDS_HOST_PREFIX}${NC}"
    return
  fi

  echo -e "${GREEN}Building CycloneDDS host tools...${NC}"
  cmake cyclonedds -B "${CYCLONEDDS_HOST_BUILD_DIR}" \
    -DBUILD_IDLC=ON -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX="${CYCLONEDDS_HOST_PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SECURITY=OFF -DENABLE_SSL=OFF -DENABLE_SHM=OFF \
    -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DDSPERF=OFF
  cmake --build "${CYCLONEDDS_HOST_BUILD_DIR}" --target install -j"$(nproc)"
}

function require_nros_checkout() {
  if [ ! -d "${ROOT_DIR}"/modules/nros ]; then
    echo -e "${RED}nano-ros checkout missing at modules/nros.${NC}" 1>&2
    echo -e "${YELLOW}Run \`west update\` to fetch nano-ros from the manifest.${NC}" 1>&2
    exit 1
  fi
}

# Phase 5 W1 — messages resolve from the AMENT environment (the vendored
# msg_ros/ copies are gone). A sourced ROS 2 + Autoware env wins; otherwise
# compose existence-gated defaults (/opt/ros/humble + the newest
# /opt/autoware/<ver>, which is the devcontainer layout too), then verify the
# packages the codegen needs actually resolve so the failure is one clear
# message here instead of a cmake FATAL_ERROR four levels down.
function resolve_ament_env() {
  if [ -z "${AMENT_PREFIX_PATH:-}" ]; then
    local rungs=()
    [ -d /opt/ros/humble/share ] && rungs+=(/opt/ros/humble)
    local d
    for d in $(ls -d /opt/autoware/*/share 2>/dev/null | sort -Vr); do
      rungs+=("$(dirname "${d}")")
    done
    if [ ${#rungs[@]} -gt 0 ]; then
      AMENT_PREFIX_PATH=$(IFS=:; echo "${rungs[*]}")
      export AMENT_PREFIX_PATH
      echo -e "${GREEN}AMENT_PREFIX_PATH not set — using: ${AMENT_PREFIX_PATH}${NC}"
    fi
  fi
  local probe="" prefix
  local IFS=:
  for prefix in ${AMENT_PREFIX_PATH:-}; do
    if [ -f "${prefix}/share/autoware_planning_msgs/msg/TrajectoryPoint.msg" ] ; then
      probe=1
    fi
  done
  if [ -z "${probe}" ]; then
    echo -e "${RED}autoware_planning_msgs not found in AMENT_PREFIX_PATH.${NC}" 1>&2
    echo -e "${YELLOW}Source a ROS 2 Humble + Autoware environment (or set AMENT_PREFIX_PATH)"\
" — message .msg sources resolve from it since phase-5 W1.${NC}" 1>&2
    exit 1
  fi
}

function build_zephyr_actuation_module() {
  echo -e "${GREEN}Building Zephyr Actuation Module (nano-ros)...${NC}"
  # Phase 3 W1 (nano-ros branch) — the Zephyr platforms run on nano-ros:
  # messages come from `nros_generate_interfaces()` (host `nros` CLI) and the
  # RMW is the nano-ros Zephyr module, so the vendored-CycloneDDS host tooling
  # upstream's Zephyr path used (idlc PATH + -DCYCLONEDDS_SRC) is not needed
  # here. The FreeRTOS platforms below still use it unchanged.
  require_nros_checkout
  # Build the host `nros` CLI if missing or stale (full host provisioning is
  # scripts/bootstrap-asi.sh; this only ensures the CLI binary). Phase 3 W2.c
  # — inlined from the retired bootstrap-nano-ros-shim.sh.
  local nros_cli_manifest="${ROOT_DIR}/modules/nros/packages/cli/Cargo.toml"
  local nros_cli_bin="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"
  if [ ! -f "${nros_cli_manifest}" ]; then
    echo -e "${RED}nano-ros CLI manifest missing (${nros_cli_manifest}) — bump the west.yml nano-ros revision.${NC}" 1>&2
    exit 1
  fi
  if [ ! -x "${nros_cli_bin}" ] || [ "${nros_cli_manifest}" -nt "${nros_cli_bin}" ] \
     || find "${ROOT_DIR}/modules/nros/packages/cli" -name '*.rs' -newer "${nros_cli_bin}" -print -quit 2>/dev/null | grep -q .; then
    echo -e "${GREEN}Building host nros CLI...${NC}"
    cargo build --release --manifest-path "${nros_cli_manifest}" -p nros-cli
  fi
  # CMAKE_PREFIX_PATH stays cleared (host ROS cmake packages must not leak
  # into the cross build); AMENT_PREFIX_PATH is now REQUIRED for message
  # resolution (phase-5 W1) and resolved/validated here.
  export CMAKE_PREFIX_PATH=""
  resolve_ament_env
  # The nros CLI must be on PATH for the module's SDK-store lookups
  # (`find_program(nros)` feeds `nros sdk-path cyclonedds` → host idlc hints;
  # a fresh configure without it dies "host Cyclone idlc not found" even with
  # a fully provisioned store). The posix lane has always done this; the
  # zephyr lane coasted on stale CMake caches until the phase-5 W1 clean
  # reconfigure exposed it.
  export PATH="$(dirname "${nros_cli_bin}"):${PATH}"
  # Board-facts lane (nano-ros phase-351 W5): `nros ws board-facts` resolves
  # the nano-ros checkout from NROS_REPO_DIR when the app dir sits outside
  # the nano-ros tree (the cmake wrapper passes no --nano-ros-path).
  export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"
  local extra_conf_files=()

  # Zephyr 3.7 hardware-model-v2 board identifiers: the HWMv1 short name
  # `fvp_baser_aemv8r_smp` is ambiguous (`fvp_baser_aemv8r` defines multiple
  # SoCs) — `west build -b` needs the full board/soc/variant id. The board
  # conf files in actuation_module/boards/ carry the HWMv2 basename too.
  local board_id="${ZEPHYR_TARGET}"
  local conf_base="${ZEPHYR_TARGET%%@*}"
  if [ "${ZEPHYR_TARGET}" = "fvp_baser_aemv8r_smp" ]; then
    board_id="fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp"
    conf_base="fvp_baser_aemv8r_fvp_aemv8r_aarch64_smp"
  fi

  # nano-ros overlay (Kconfig surface for the module) is always on for the
  # Zephyr platforms.
  extra_conf_files+=("${ROOT_DIR}/actuation_module/nano_ros_overlay.conf")

  # The Autoware trajectory follower declares ~150 node parameters (MPC
  # lateral + PID longitudinal); nano-ros's parameter server is a static
  # pool sized at Rust build time (nros-params build.rs, default 32 ->
  # declare_parameter fails with ErrorCode::Full = -5 at boot).
  #
  # ZEPHYR LANE CAVEAT (nano-ros issue 0749 follow-up): these knobs reach
  # the Zephyr Rust lane only since nano-ros d1c5b3b3b — before that the
  # curated cargo env dropped them and every Zephyr image silently built the
  # crate defaults (1024-byte subscription buffers: real trajectories were
  # ACKed and discarded with no diagnostics). NROS_MAX_PARAMETERS is pinned
  # to the old effective value 32 here because 256 HANGS Zephyr boot right
  # after dds_create_participant (bisected 2026-08-22; suspected large-store
  # stack temp upstream). Params past the 32nd fall back to compiled
  # defaults — the behavior every Zephyr image has always had. Raise after
  # the upstream hang is fixed.
  export NROS_MAX_PARAMETERS="${NROS_MAX_PARAMETERS:-32}"
  # Executor sizing (nros-node build.rs): the controller registers 5
  # subscriptions + timers + publishers (default MAX_CBS=4 → creation fails
  # with TransportError at boot), and /planning trajectories run 9-14 KiB
  # (default per-subscription RX buffer is 1 KiB). The arena would derive to
  # ~1 MB from MAX_CBS=16 x 16 KiB buffers (action-client worst case); cap
  # it at what this image actually needs.
  export NROS_EXECUTOR_MAX_CBS="${NROS_EXECUTOR_MAX_CBS:-16}"
  export NROS_SUBSCRIPTION_BUFFER_SIZE="${NROS_SUBSCRIPTION_BUFFER_SIZE:-16384}"
  export NROS_EXECUTOR_ARENA_SIZE="${NROS_EXECUTOR_ARENA_SIZE:-458752}"

  # Pass the resolved host path of the `nros` CLI to CMake — the Zephyr module
  # resolves the codegen tool from `_NANO_ROS_CODEGEN_TOOL` (then $NROS_CLI,
  # then PATH); see modules/nros/zephyr/cmake/nros_generate_interfaces.cmake.
  local nros_codegen="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"

  # Build command with common arguments
  local build_args=(
    -DZEPHYR_TARGET="${ZEPHYR_TARGET}"
    -D_NANO_ROS_CODEGEN_TOOL="${nros_codegen}"
    -DEXTRA_CFLAGS="-Wno-error"
    -DEXTRA_CXXFLAGS="-Wno-error"
    "-DBUILD_TEST=${BUILD_TEST_FLAG}"
    # Issue 0745 — the bringup declares [system].features=["param_services"]
    # (launch-param seeding); the Zephyr module lane has no bringup-driven
    # capability resolution yet, so mirror it explicitly.
    -DNANO_ROS_FEATURES="param_services"
  )

  local board_conf="${ROOT_DIR}/actuation_module/boards/${conf_base}_actuation.conf"
  if [ -f "${board_conf}" ]; then
    extra_conf_files+=("${board_conf}")
  fi

  # The FVP's SMSC 91C111 ethernet model defaults to disabled
  # (bp.smsc_91c111.enabled=0); without it Zephyr's eth_smsc91x probe fails
  # ("Identification value not in BSR", MAC 00:00:00:00:00:00) and the net
  # stack times out waiting for the interface. Enable it for every FVP run;
  # promiscuous so the guest sees DDS multicast frames off the host bridge.
  export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS:-} -C bp.smsc_91c111.enabled=1 -C bp.smsc_91c111.promiscuous=1"

  if [ "${NETWORK_PROFILE}" = "tap" ]; then
    extra_conf_files+=("${ROOT_DIR}/actuation_module/boards/${conf_base}_tap_network.conf")
    local fvp_tap_interface="${FVP_TAP_INTERFACE:-tap0}"
    export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS} -C bp.hostbridge.userNetworking=0 -C bp.hostbridge.interfaceName=${fvp_tap_interface}"
  fi

  # Add device tree overlay only for ARM board variant
  if [ "${ZEPHYR_TARGET}" = "s32z270dc2_rtu0_r52@D" ]; then
    build_args+=(-DEXTRA_DTC_OVERLAY_FILE="${ROOT_DIR}"/actuation_module/boards/s32z270dc2_rtu0_r52@D.overlay)
  fi

  local can_loopback_conf="${ROOT_DIR}/actuation_module/boards/${conf_base}_can_loopback.conf"
  local can_loopback_overlay="${ROOT_DIR}/actuation_module/boards/${conf_base}_can_loopback.overlay"
  if [ "${BUILD_TEST_FLAG}" = "4" ]; then
    if [ -f "${can_loopback_conf}" ]; then
      extra_conf_files+=("${can_loopback_conf}")
    fi
    if [ -f "${can_loopback_overlay}" ]; then
      build_args+=(-DEXTRA_DTC_OVERLAY_FILE="${can_loopback_overlay}")
    fi
  fi

  if [ "${#extra_conf_files[@]}" -gt 0 ]; then
    local extra_conf_file
    extra_conf_file=$(IFS=';'; echo "${extra_conf_files[*]}")
    build_args+=(-DEXTRA_CONF_FILE="${extra_conf_file}")
  fi

  west build -p auto -d "${BUILD_DIR}" -b "${board_id}" actuation_module/ -- "${build_args[@]}"
}

function build_freertos_posix() {
  # Phase 4 W5.a — nano-ros workspace mode (nros-board-freertos-posix,
  # nano-ros phase-370): host process, board-owned main()/scheduler, nodes
  # as FreeRTOS tasks over HOST CycloneDDS (self-provisioned from the
  # pinned fork; no vendored-cyclonedds involvement).
  echo -e "${GREEN}Building FreeRTOS POSIX runtime (nano-ros workspace mode)...${NC}"
  if [ "${BUILD_TEST_FLAG}" != "0" ]; then
    echo -e "${RED}test programs are Zephyr-lane only; the FreeRTOS POSIX lane builds the controller image${NC}" 1>&2
    exit 1
  fi

  require_nros_checkout
  local nros_cli_manifest="${ROOT_DIR}/modules/nros/packages/cli/Cargo.toml"
  local nros_cli_bin="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"
  if [ ! -x "${nros_cli_bin}" ]; then
    echo -e "${GREEN}Building host nros CLI...${NC}"
    cargo build --release --manifest-path "${nros_cli_manifest}" -p nros-cli
  fi
  # CMAKE_PREFIX_PATH stays cleared (host ROS cmake packages must not leak
  # into the cross build); AMENT_PREFIX_PATH is now REQUIRED for message
  # resolution (phase-5 W1) and resolved/validated here.
  export CMAKE_PREFIX_PATH=""
  resolve_ament_env
  export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"
  # `nros sync` spawns its own cmake probes that resolve the codegen tool
  # from PATH/~/.nros/bin — our -D_NANO_ROS_CODEGEN_TOOL doesn't reach them.
  export PATH="$(dirname "${nros_cli_bin}"):${PATH}"

  # FreeRTOS kernel source — nros-provisioned (phase-4 kernel-provenance
  # decision: nano-ros's index-pinned checkout is the SSOT).
  export FREERTOS_DIR="${FREERTOS_DIR:-${ROOT_DIR}/modules/nros/third-party/freertos/kernel}"
  if [ ! -d "${FREERTOS_DIR}/portable/ThirdParty/GCC/Posix" ]; then
    echo -e "${RED}FreeRTOS kernel missing at ${FREERTOS_DIR}.${NC}" 1>&2
    echo -e "${YELLOW}Run: (cd modules/nros && ./packages/cli/target/release/nros setup --source freertos-kernel)${NC}" 1>&2
    exit 1
  fi

  # Same sizing knobs as the Zephyr lane (environment wins over defaults):
  # the controller declares 150+ parameters and 8.8 KiB trajectory samples.
  export NROS_MAX_PARAMETERS="${NROS_MAX_PARAMETERS:-256}"
  export NROS_EXECUTOR_MAX_CBS="${NROS_EXECUTOR_MAX_CBS:-16}"
  export NROS_SUBSCRIPTION_BUFFER_SIZE="${NROS_SUBSCRIPTION_BUFFER_SIZE:-16384}"

  local app_build_dir
  app_build_dir=$(realpath -m "${BUILD_DIR}")

  ( cd "${ROOT_DIR}/actuation_module" && "${nros_cli_bin}" sync . )

  cmake -S actuation_module -B "${app_build_dir}" \
    -DNANO_ROS_PLATFORM=freertos \
    -DNANO_ROS_BOARD=freertos-posix \
    -DNROS_RMW=cyclonedds \
    -Dnano_ros_ROOT="${ROOT_DIR}/modules/nros" \
    -DNROS_CLI_BIN="${nros_cli_bin}" \
    -D_NANO_ROS_CODEGEN_TOOL="${nros_cli_bin}"
  cmake --build "${app_build_dir}" --target actuation_posix_entry -j"$(nproc)"
}

function build_freertos_s32z2() {
  echo -e "${GREEN}Building FreeRTOS S32Z2 target...${NC}"
  echo -e "${YELLOW}This target requires NXP S32Z2 RTD, FreeRTOS, lwIP, and S32 Config Tools output.${NC}"

  local app_build_dir
  app_build_dir=$(realpath -m "${BUILD_DIR}")
  local cdds_target_build_dir="${FREERTOS_S32Z2_CDDS_TARGET_BUILD_DIR:-${app_build_dir}/cdds_target}"
  local cdds_target_prefix="${FREERTOS_S32Z2_CDDS_TARGET_PREFIX:-${app_build_dir}/cdds_target_out}"

  build_cyclonedds_host

  FREERTOS_S32Z2_BUILD_ROOT="${app_build_dir}" \
  FREERTOS_S32Z2_CDDS_HOST_PREFIX="${CYCLONEDDS_HOST_PREFIX}" \
  FREERTOS_S32Z2_CDDS_TARGET_BUILD_DIR="${cdds_target_build_dir}" \
  FREERTOS_S32Z2_CDDS_TARGET_PREFIX="${cdds_target_prefix}" \
    "${ROOT_DIR}/actuation_module/freertos_s32z2/scripts/build-cdds-target.sh"

  local freertos_args=(
    actuation_module/freertos_s32z2
    -B "${app_build_dir}"
    -DCMAKE_TOOLCHAIN_FILE="${ROOT_DIR}/actuation_module/freertos_s32z2/cmake/arm-cortex-r52.cmake"
    -DCDDS_HOST_PREFIX="${CYCLONEDDS_HOST_PREFIX}"
    -DCDDS_TARGET_PREFIX="${cdds_target_prefix}"
  )

  if [ -n "${DDS_NETWORK_INTERFACE}" ]; then
    freertos_args+=(-DCONFIG_DDS_NETWORK_INTERFACE="${DDS_NETWORK_INTERFACE}")
  fi
  if [ -n "${CONTROL_CMD_OUTPUT_MODE}" ]; then
    freertos_args+=(-DCONFIG_CONTROL_CMD_OUTPUT_MODE="${CONTROL_CMD_OUTPUT_MODE}")
  fi

  cmake "${freertos_args[@]}"
  cmake --build "${app_build_dir}" -j"$(nproc)"
}

## MAIN ##
parse_args "$@"
normalize_platform

# Create build directory
cd "${ROOT_DIR}"
mkdir -p build

case "${BUILD_PLATFORM}" in
  zephyr-fvp|zephyr-s32z)
    build_zephyr_actuation_module
    ;;
  freertos-posix)
    build_freertos_posix
    ;;
  freertos-s32z2)
    build_freertos_s32z2
    ;;
esac
