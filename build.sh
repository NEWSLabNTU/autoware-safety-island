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
CYCLONEDDS_TARGET_BUILD_DIR=${CYCLONEDDS_TARGET_BUILD_DIR:-"${ROOT_DIR}/build/cyclonedds_target"}
CYCLONEDDS_TARGET_PREFIX=${CYCLONEDDS_TARGET_PREFIX:-"${ROOT_DIR}/build/cyclonedds_target_out"}

# Build options
BUILD_TEST_FLAG=0
BUILD_DIR="build/actuation_module"
BUILD_DIR_SET=0
BUILD_PLATFORM="zephyr-fvp"
BUILD_PLATFORM_SET=0
NETWORK_PROFILE="default"
TRACE_ENABLED=0
TRACE_STATS_ENABLED=0
TRACE_RING_ENABLED=0
RUNTIME_TARGET_LIST=("zephyr-fvp" "zephyr-s32z" "freertos-posix" "freertos-posix-carla" "freertos-s32z2" "freertos-an536")
ZEPHYR_TARGET_LIST=("fvp_baser_aemv8r_smp" "s32z270dc2_rtu0_r52@D")
ZEPHYR_TARGET=${ZEPHYR_TARGET_LIST[0]} # Default target is fvp_baser_aemv8r_smp
ZEPHYR_TARGET_SET=0

function usage() {
  echo -e "${GREEN}Usage: $0 [OPTIONS]${NC}"
  echo -e "------------------------------------------------"
  echo -e "${GREEN}    --platform         ${NC}Runtime target: ${RUNTIME_TARGET_LIST[*]}."
  echo -e "${GREEN}                         default: zephyr-fvp.${NC}"
  echo -e "${GREEN}    --network          ${NC}Network profile: default, tap. tap is valid for zephyr-fvp."
  echo -e "${GREEN}    -t                 ${NC}Zephyr target board: ${ZEPHYR_TARGET_LIST[*]}"
  echo -e "${GREEN}                         default: ${ZEPHYR_TARGET_LIST[0]}.${NC}"
  echo -e "${GREEN}    -d                 ${NC}Build directory. Default: ${BUILD_DIR}."
  echo -e "${GREEN}    --trace-stats      ${NC}Thread runtime scheduling statistics only (no CTF)."
  echo -e "${GREEN}    --trace-ring       ${NC}CTF into an overwrite-oldest RAM ring (flight recorder)."
  echo -e "${GREEN}    --trace            ${NC}Zephyr FVP only: build with CTF tracing + thread runtime"
  echo -e "${GREEN}                         stats, streaming the trace to uart1. See"
  echo -e "${GREEN}                         documentation/design/rt_evaluation_zephyr.rst.${NC}"
  echo -e "${GREEN}    --run              ${NC}Zephyr only: start the model for an already-built -d"
  echo -e "${GREEN}                         directory, in the same environment the build had.${NC}"
  echo -e "${GREEN}    --dev-cli          ${NC}Build the nros CLI from modules/nros (NROS_DEV_CLI=1)"
  echo -e "${GREEN}                         instead of the release actuation_module/nros-toolchain.toml pins.${NC}"
  echo -e "${GREEN}    -c                 ${NC}Clean all builds and exit."
  echo -e "${GREEN}    -h                 ${NC}Display the usage and exit."
  echo ""
  echo -e "${GREEN}    Optional arguments to build test programs:${NC}"
  echo -e "${GREEN}    --unit-test        ${NC}Build unit test program."
  echo -e "${GREEN}    --dds-publisher    ${NC}Build DDS publisher test program."
  echo -e "${GREEN}    --dds-subscriber   ${NC}Build DDS subscriber test program."
  echo -e "${GREEN}    --can-output-test  ${NC}Build CAN output test program (freertos-posix: the"
  echo -e "${GREEN}                       ${NC}controller image plus the can_vcan_sender host program)."
  echo -e "${GREEN}    --dds-loopback-test${NC}Build Zephyr DDS loopback test program."
  echo ""
  echo -e "${GREEN}    Runtime target matrix:${NC}"
  echo -e "    zephyr-fvp       Zephyr on Arm FVP for local validation / AVH."
  echo -e "    zephyr-s32z      Zephyr on S32Z hardware."
  echo -e "    freertos-posix   FreeRTOS POSIX runtime for local validation."
  echo -e "    freertos-posix-carla  The POSIX runtime bound to the CARLA ego (integration/carla)."
  echo -e "    freertos-s32z2   FreeRTOS on S32Z2 hardware (nano-ros lane, phase-4 W5.b)."
  echo -e "    freertos-an536   FreeRTOS on QEMU mps3-an536 (emulated Cortex-R52; phase-6)."
  echo ""
  echo -e "${GREEN}    Examples:${NC}"
  echo -e "    $0 --platform zephyr-fvp --network tap -d build/zephyr-fvp-tap"
  echo -e "    $0 --platform freertos-posix -d build/freertos-posix"
  echo -e "    $0 --platform freertos-s32z2 -d build/freertos-s32z2"
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
      --dev-cli)
        # Build the nros CLI from modules/nros instead of the pinned release
        # (scripts/nros-cli.sh): for nano-ros changes no release has yet.
        export NROS_DEV_CLI=1
        shift
        ;;
      --run)
        # Start the model for an ALREADY-BUILT -d directory, in the same
        # environment a build gets. See ZEPHYR_RUN_ONLY in
        # build_zephyr_actuation_module for why the run has to come from here.
        ZEPHYR_RUN_ONLY=1
        shift
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
      --trace)
        TRACE_ENABLED=1
        shift
        ;;
      --trace-ring)
        # Implies --trace: the ring chooses WHERE the stream goes, it does not
        # turn tracing on.
        TRACE_ENABLED=1
        TRACE_RING_ENABLED=1
        shift
        ;;
      --trace-stats)
        TRACE_STATS_ENABLED=1
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
    freertos-posix-carla)
      if [ "${ZEPHYR_TARGET_SET}" = "1" ]; then
        echo -e "${RED}-t is only valid for Zephyr platforms${NC}" 1>&2
        exit 1
      fi
      if [ "${BUILD_DIR_SET}" = "0" ]; then
        BUILD_DIR="build/freertos-posix-carla"
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
    freertos-an536)
      if [ "${ZEPHYR_TARGET_SET}" = "1" ]; then
        echo -e "${RED}-t is only valid for Zephyr platforms${NC}" 1>&2
        exit 1
      fi
      if [ "${BUILD_DIR_SET}" = "0" ]; then
        BUILD_DIR="build/freertos-an536"
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

  if [ "${BUILD_PLATFORM}" = "freertos-s32z2" ] && [ "${BUILD_TEST_FLAG}" != "0" ]; then
    echo -e "${RED}Test build options are not supported for --platform freertos-s32z2${NC}" 1>&2
    exit 1
  fi
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

# Phase 5 W1 — messages resolve from the AMENT environment (the vendored
# msg_ros/ copies are gone). A sourced ROS 2 + Autoware env wins; otherwise
# compose existence-gated defaults (/opt/ros/humble + the newest
# /opt/autoware/<ver>, which is the devcontainer layout too), then verify the
# packages the codegen needs actually resolve so the failure is one clear
# message here instead of a cmake FATAL_ERROR four levels down.
# The nros CLI: the released one actuation_module/nros-toolchain.toml pins,
# or (NROS_DEV_CLI=1) one built from modules/nros. See scripts/nros-cli.sh.
# shellcheck source=scripts/nros-cli.sh
. "${ROOT_DIR}/scripts/nros-cli.sh"

# Message-source resolution (AMENT_PREFIX_PATH). Sourced rather than inline so
# the FVP CI script resolves the SAME prefixes before `west build --target run`
# re-enters cmake.
# shellcheck source=scripts/ament-env.sh
. "${ROOT_DIR}/scripts/ament-env.sh"

# --run: start the model for an ALREADY-BUILT -d directory. Needs only the
# build dir and ARMFVP_BIN_PATH, so it runs BEFORE anything that touches
# cargo. It used to run after the CLI build, and that "~0.1 s no-op" waits
# on the shared ~/.cargo package-cache lock whenever another session's build
# or test holds it: a model launch that needs no compiler at all sat blocked
# on one for as long as the other session kept it.
function run_zephyr_model() {
  if [ ! -f "${BUILD_DIR}/zephyr/zephyr.elf" ]; then
    echo -e "${RED}--run: no ELF at ${BUILD_DIR}/zephyr/zephyr.elf — build first.${NC}" 1>&2
    exit 1
  fi
  local ninja_file="${BUILD_DIR}/build.ninja"
  if [ ! -f "${ninja_file}" ]; then
    echo -e "${RED}--run: no build.ninja in ${BUILD_DIR}.${NC}" 1>&2
    exit 1
  fi
  # The `run_armfvp` custom command, verbatim: `cd <dir> && <fvp> -C ... -a elf`.
  # Ninja escapes `$` as `$$` and a literal space in a path as `$ `; undo both.
  local run_cmd
  run_cmd="$(awk '/Custom command for zephyr\/CMakeFiles\/run_armfvp/{f=1} f && /^  COMMAND = /{sub(/^  COMMAND = /,""); print; exit}' \
             "${ninja_file}" | sed 's/\$\$/$/g; s/\$ / /g')"
  if [ -z "${run_cmd}" ]; then
    echo -e "${RED}--run: no run_armfvp command in ${ninja_file}.${NC}" 1>&2
    echo -e "${YELLOW}The board's run target is what supplies the model command line.${NC}" 1>&2
    exit 1
  fi
  # ARMFVP-NOTFOUND is what cmake records when no model was on PATH at
  # CONFIGURE time. Substitute the one resolved now rather than failing with
  # a shell "command not found", which says nothing about the cause.
  if [ "${run_cmd#*ARMFVP-NOTFOUND}" != "${run_cmd}" ]; then
    if [ -n "${ARMFVP_BIN_PATH:-}" ] && [ -x "${ARMFVP_BIN_PATH}/FVP_BaseR_AEMv8R" ]; then
      run_cmd="${run_cmd//ARMFVP-NOTFOUND/${ARMFVP_BIN_PATH}/FVP_BaseR_AEMv8R}"
    else
      echo -e "${RED}--run: this build dir was configured with no FVP on PATH${NC}" 1>&2
      echo -e "${YELLOW}(cmake recorded ARMFVP-NOTFOUND). Set ARMFVP_BIN_PATH, or rebuild"\
" with the model installed.${NC}" 1>&2
      exit 1
    fi
  fi
  echo -e "${GREEN}Starting the model for ${BUILD_DIR}...${NC}"
  # Subshell: the recorded command begins with a `cd`, and that must not
  # follow us back into the rest of this script.
  ( eval "${run_cmd}" )
}

# The Zephyr environment every Zephyr build gets: the host nros CLI (on
# PATH, scripts/nros-cli.sh), the message prefixes, nano-ros's checkout, and the FVP
# model flags. Shared by the controller images and the test programs.
function zephyr_env() {
  require_nros_checkout
  # This repo's Zephyr patches (patches/zephyr): a fresh checkout or a
  # provisioning run leaves them out, and a trace image does not link
  # without 0002. Idempotent; a conflicting patch stops the build.
  "${ROOT_DIR}/scripts/apply-zephyr-patches.sh" "${ROOT_DIR}/zephyr"
  nros_cli_select || exit 1
  NROS_CLI_BIN="${NROS_CLI}"
  if [ "${NROS_CLI_MODE}" = "release" ]; then
    # The Zephyr module's Cyclone DDS is a checkout source in the release's
    # tree, provisioned on first use (with --dev-cli it is modules/nros's
    # submodule). Idempotent.
    ( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" setup --source cyclonedds-src ) || exit 1
  fi
  # CMAKE_PREFIX_PATH stays cleared (host ROS cmake packages must not leak
  # into the cross build); AMENT_PREFIX_PATH resolves the messages.
  export CMAKE_PREFIX_PATH=""
  resolve_ament_env
  # The Zephyr module resolves the codegen tool and the SDK store through the
  # CLI on PATH, and nano-ros's checkout through NROS_REPO_DIR.
  export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"

  # The FVP's SMSC 91C111 ethernet model defaults to disabled
  # (bp.smsc_91c111.enabled=0); without it Zephyr's eth_smsc91x probe fails
  # ("Identification value not in BSR", MAC 00:00:00:00:00:00) and the net
  # stack times out waiting for the interface. Enable it for every FVP run;
  # promiscuous so the guest sees DDS multicast frames off the host bridge.
  # armfvp.cmake reads ARMFVP_EXTRA_FLAGS from the environment at CONFIGURE
  # time and bakes it into the `run` target, which `--run` replays.
  export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS:-} -C bp.smsc_91c111.enabled=1 -C bp.smsc_91c111.promiscuous=1"
  if [ "${NETWORK_PROFILE}" = "tap" ]; then
    local fvp_tap_interface="${FVP_TAP_INTERFACE:-tap0}"
    export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS} -C bp.hostbridge.userNetworking=0 -C bp.hostbridge.interfaceName=${fvp_tap_interface}"
  fi
  if [ "${TRACE_ENABLED}" = "1" ]; then
    # -d may be relative or absolute, so resolve rather than prefix ROOT_DIR.
    local trace_out="${TRACE_OUT_FILE:-$(realpath -m "${BUILD_DIR}")/trace.ctf}"
    mkdir -p "$(dirname "${trace_out}")"
    # board.cmake aims every FVP PL011 at stdout (out_file=-); send uart1 to a
    # file instead so the CTF octet stream is not interleaved with the console.
    export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS} -C bp.pl011_uart1.out_file=${trace_out}"
    echo -e "${GREEN}Tracing enabled: CTF stream -> ${trace_out}${NC}"
  fi
}

# The bringup image a controller build is: [image.<id>] in
# actuation_module/src/controller_bringup/system.toml.
function zephyr_image_id() {
  if [ "${BUILD_PLATFORM}" = "zephyr-s32z" ]; then
    if [ "${TRACE_ENABLED}" = "1" ] || [ "${TRACE_STATS_ENABLED}" = "1" ]; then
      echo -e "${RED}--trace / --trace-stats are FVP images only.${NC}" 1>&2
      exit 1
    fi
    echo "s32z"
    return
  fi
  local id="fvp"
  if [ "${NETWORK_PROFILE}" = "tap" ]; then
    id="${id}-tap"
  fi
  if [ "${TRACE_RING_ENABLED}" = "1" ]; then
    id="${id}-trace-ring"
  elif [ "${TRACE_ENABLED}" = "1" ]; then
    id="${id}-trace"
  elif [ "${TRACE_STATS_ENABLED}" = "1" ]; then
    id="${id}-stats"
  fi
  echo "${id}"
}

# The controller images: `nros build <image>` generates the west application
# from the image row (board, domain, os_config fragments, sizing knobs) and
# runs west on it, into the -d directory.
function build_zephyr_controller() {
  local image
  image="$(zephyr_image_id)"
  echo -e "${GREEN}Building Zephyr controller image (nros build ${image})...${NC}"
  local build_dir
  build_dir="$(realpath -m "${BUILD_DIR}")"
  # West's own options go before the CMake ones; nros build routes each.
  local native=(-d "${build_dir}" -p auto
    -DEXTRA_CFLAGS=-Wno-error -DEXTRA_CXXFLAGS=-Wno-error)
  ( cd "${ROOT_DIR}/actuation_module" && \
      "${NROS_CLI_BIN}" build "${image}" --zephyr-workspace "${ROOT_DIR}" -- "${native[@]}" )
}

# The Zephyr test programs (--unit-test, --dds-publisher, --dds-subscriber,
# --can-output-test, --dds-loopback-test): hand-written main()s, built by
# their own west application, actuation_module/test/zephyr_app (nano-ros's
# "A Zephyr app you build with west": no bringup image, no generated entry),
# one program per build. They take the controller images' Kconfig
# fragments, so a test runs on the configuration the controller ships with.
function build_zephyr_test() {
  local tests=("" unit_test dds_pub dds_sub can_output_test dds_loopback_test)
  local test="${tests[${BUILD_TEST_FLAG}]}"
  echo -e "${GREEN}Building Zephyr test program ${test}...${NC}"
  local app="${ROOT_DIR}/actuation_module/test/zephyr_app"
  local zconf="${ROOT_DIR}/actuation_module/src/controller_bringup/zephyr"

  # Zephyr 3.7 hardware-model-v2 board identifiers.
  local board_id="fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp"
  local confs=("${app}/nano_ros.conf" "${zconf}/prj-fvp.conf")
  if [ "${BUILD_PLATFORM}" = "zephyr-s32z" ]; then
    board_id="s32z270dc2_rtu0_r52@D"
    confs=("${app}/nano_ros.conf" "${zconf}/prj-s32z.conf")
  fi
  # The network the user-mode controller images state in a board network
  # file (controller_bringup/zephyr/net-fvp.toml), as nros build renders it;
  # the tap images and the S32Z state their own (prj-fvp-tap.conf,
  # prj-s32z.conf).
  if [ "${NETWORK_PROFILE}" = "tap" ]; then
    confs+=("${zconf}/prj-fvp-tap.conf")
  elif [ "${BUILD_PLATFORM}" != "zephyr-s32z" ]; then
    confs+=("${app}/net-fvp.conf")
  fi
  local overlays=()
  if [ "${BUILD_TEST_FLAG}" = "4" ] && [ "${NETWORK_PROFILE}" = "tap" ]; then
    # On the tap network the CAN frames leave over the FVP UDP tunnel to the
    # host gateway (actuation_module/test/run-fvp-tap-tunnel.sh), not the
    # CAN loopback device.
    confs+=("${app}/output_can_only.conf" "${app}/can_udp_tunnel.conf")
  elif [ "${BUILD_TEST_FLAG}" = "4" ]; then
    confs+=("${app}/can_loopback.conf")
    overlays+=("${app}/can_loopback.overlay")
  fi
  if [ "${TRACE_STATS_ENABLED}" = "1" ] || [ "${TRACE_ENABLED}" = "1" ]; then
    confs+=("${zconf}/prj-trace-stats.conf")
  fi
  if [ "${TRACE_ENABLED}" = "1" ]; then
    confs+=("${zconf}/prj-trace.conf")
    if [ "${TRACE_RING_ENABLED}" = "1" ]; then
      confs+=("${zconf}/prj-trace-ring.conf")
    fi
    overlays+=("${zconf}/fvp-trace.overlay")
  fi

  # A test program is no bringup image, so it has no knob rows: the sizing
  # the controller images state in system.toml reaches it from the
  # environment, the same values (an exported value wins over a row).
  export NROS_MAX_PARAMETERS="${NROS_MAX_PARAMETERS:-164}"
  export NROS_EXECUTOR_MAX_CBS="${NROS_EXECUTOR_MAX_CBS:-16}"
  export NROS_SUBSCRIPTION_BUFFER_SIZE="${NROS_SUBSCRIPTION_BUFFER_SIZE:-16384}"
  if [ "${BUILD_PLATFORM}" = "zephyr-s32z" ]; then
    export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-2097152}"
  else
    export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-8388608}"
  fi

  local build_args=(
    -DASI_TEST="${test}"
    -D_NANO_ROS_CODEGEN_TOOL="${NROS_CLI_BIN}"
    -DEXTRA_CFLAGS="-Wno-error"
    -DEXTRA_CXXFLAGS="-Wno-error"
    -DNROS_FEATURES="param_services"
    -DEXTRA_CONF_FILE="$(IFS=';'; echo "${confs[*]}")"
  )
  if [ "${#overlays[@]}" -gt 0 ]; then
    build_args+=(-DEXTRA_DTC_OVERLAY_FILE="$(IFS=';'; echo "${overlays[*]}")")
  fi
  # The configure's message inventory is a build artifact `nros configure`
  # writes.
  ( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI_BIN}" configure . )
  west build -p auto -d "${BUILD_DIR}" -b "${board_id}" "${app}" -- "${build_args[@]}"
}

function build_zephyr_actuation_module() {
  if [ "${ZEPHYR_RUN_ONLY:-0}" = "1" ]; then
    run_zephyr_model
    return
  fi
  zephyr_env
  if [ "${BUILD_TEST_FLAG}" = "0" ]; then
    build_zephyr_controller
  else
    build_zephyr_test
  fi
}


# The FreeRTOS images -- the POSIX simulator, QEMU mps3-an536 and NXP
# S32Z270 hardware -- are `[image.freertos-posix]`, `[image.an536]` and
# `[image.s32z2]` in controller_bringup/system.toml, built by
# `nros build <image>`: nano-ros generates the workspace root and the entry
# from the image row (board, domain, sizing knobs), so this only provisions the
# environment and forwards the facts a build machine supplies.
#
#   $1 image id          freertos-posix | an536 | s32z2
#   $2 human label       e.g. "S32Z2"
#   $3 artifact name     the link left at ${BUILD_DIR}/<name>
function build_freertos_nros() {
  local image="$1"
  local label="$2"
  local artifact_name="$3"
  echo -e "${GREEN}Building FreeRTOS ${label} runtime (nros build ${image})...${NC}"
  # The test programs are the Zephyr lane's, with one exception: on the POSIX
  # simulator --can-output-test also builds can_vcan_sender, the host SocketCAN
  # sender actuation_module/test/run-vcan-roundtrip.sh drives (beside the
  # controller image, which it does not replace).
  local vcan_sender=0
  if [ "${BUILD_TEST_FLAG}" = "4" ] && [ "${image}" = "freertos-posix" ]; then
    vcan_sender=1
  elif [ "${BUILD_TEST_FLAG}" != "0" ]; then
    echo -e "${RED}test programs are Zephyr-lane only (freertos-posix takes --can-output-test); this lane builds the controller image${NC}" 1>&2
    exit 1
  fi
  # The domain is the image's ([image.<id>] domain_id), rendered into the
  # generated entry. The old override would now be silently ignored.
  if [ -n "${NROS_DOMAIN_ID:-}" ]; then
    echo -e "${RED}NROS_DOMAIN_ID is no longer read: the domain is [image.${image}] domain_id in actuation_module/src/controller_bringup/system.toml.${NC}" 1>&2
    exit 1
  fi

  require_nros_checkout
  nros_cli_select || exit 1
  local nros_cli_bin="${NROS_CLI}"
  if [ "${NROS_CLI_MODE}" = "release" ] && [ "${image#freertos-posix}" = "${image}" ]; then
    # On the release path a cross board's sources (FreeRTOS kernel, lwIP, the
    # Cyclone DDS tree) come from the SDK store, not modules/nros's
    # submodules: provision the image's board the way the nano-ros book does
    # (`nros setup <board> --rmw cyclonedds`). Idempotent. The posix images
    # build against the host's Cyclone DDS and need none of it.
    local board
    board="$(awk -v img="[image.${image}]" '
      $0 == img { in_img = 1; next }
      /^\[/ { in_img = 0 }
      in_img && $1 == "board" { gsub(/"/, "", $3); print $3; exit }
    ' "${ROOT_DIR}/actuation_module/src/controller_bringup/system.toml")"
    if [ -z "${board}" ]; then
      echo -e "${RED}[image.${image}] states no board in controller_bringup/system.toml.${NC}" 1>&2
      exit 1
    fi
    ( cd "${ROOT_DIR}/actuation_module" && \
        "${nros_cli_bin}" setup "${board}" --rmw cyclonedds ) || exit 1
  fi
  export CMAKE_PREFIX_PATH=""
  resolve_ament_env
  export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"

  # The cross toolchain (the ARMv8-R boards) is the SDK store's pinned
  # arm-none-eabi-gcc, which nano-ros's toolchain file resolves itself
  # (nano-ros issue 1117); the configure prints which one it took. Provision
  # with: (cd modules/nros && nros setup --tool arm-none-eabi-gcc)

  # Native arguments to the CMake configure nros build drives. The build
  # type is the image's `profile` (system.toml).
  local native=()
  # The kernel and its port are provisioning facts, passed on only when the
  # machine states them: by default the board uses nano-ros's pinned kernel
  # and the upstream GCC/ARM_CRx_No_GIC port (link-complete). NXP hardware
  # (scripts/provision-nxp-freertos.sh) exports FREERTOS_DIR and
  # FREERTOS_PORT=GCC/ARM_CR52_GIC; asi_common then builds the pthread shim's
  # NXP task-create variants.
  if [ -n "${FREERTOS_DIR:-}" ]; then
    native+=(-DFREERTOS_DIR="${FREERTOS_DIR}")
  fi
  if [ -n "${FREERTOS_PORT:-}" ]; then
    native+=(-DFREERTOS_PORT="${FREERTOS_PORT}")
  fi
  # Stated either way: nros build reuses the image's CMake cache, where an
  # earlier ON would otherwise stay. freertos-posix-carla shares that cache
  # (same board and configuration hash), so it states the flag too.
  if [ "${image}" = "freertos-posix" ] || [ "${image}" = "freertos-posix-carla" ]; then
    if [ "${vcan_sender}" = "1" ]; then
      native+=(-DASI_CAN_VCAN_SENDER=ON)
    else
      native+=(-DASI_CAN_VCAN_SENDER=OFF)
    fi
  fi

  local log
  log="$(mktemp)"
  ( cd "${ROOT_DIR}/actuation_module" && \
      "${nros_cli_bin}" build "${image}" -- "${native[@]}" ) 2>&1 | tee "${log}"
  local rc=${PIPESTATUS[0]}
  if [ "${rc}" != "0" ]; then
    rm -f "${log}"
    exit "${rc}"
  fi
  # nros build names the artifact it produced; leave a stable link to it in
  # the build directory the caller chose.
  local artifact
  artifact="$(sed -n 's/^  artifact: //p' "${log}" | tail -1)"
  rm -f "${log}"
  if [ -z "${artifact}" ] || [ ! -f "${artifact}" ]; then
    echo -e "${RED}nros build ${image} reported no artifact.${NC}" 1>&2
    exit 1
  fi
  mkdir -p "${BUILD_DIR}"
  ln -sfn "${artifact}" "${BUILD_DIR}/${artifact_name}"
  echo -e "${GREEN}${label} image: ${BUILD_DIR}/${artifact_name} -> ${artifact}${NC}"
  if [ "${vcan_sender}" = "1" ]; then
    local sender
    sender="$(dirname "${artifact}")/can_vcan_sender"
    if [ ! -x "${sender}" ]; then
      echo -e "${RED}nros build ${image} built no can_vcan_sender (${sender}).${NC}" 1>&2
      exit 1
    fi
    ln -sfn "${sender}" "${BUILD_DIR}/can_vcan_sender"
    echo -e "${GREEN}vcan sender: ${BUILD_DIR}/can_vcan_sender -> ${sender}${NC}"
  fi
}

# The FreeRTOS POSIX simulator: a host process, board-owned main() and
# scheduler, the node as a FreeRTOS task over host CycloneDDS.
function build_freertos_posix() {
  build_freertos_nros freertos-posix "POSIX" actuation_posix_entry
}

# The same simulator bound to the CARLA ego (system.toml [image.freertos-posix-carla]).
function build_freertos_posix_carla() {
  build_freertos_nros freertos-posix-carla "POSIX (CARLA)" actuation_posix_entry
}

# The NXP S32Z270 image. Without the NXP SDK it LINK-COMPLETES against the
# board bundle's in-tree GCC/ARM_CRx_No_GIC port and weak netif stubs;
# hardware provisioning (scripts/provision-nxp-freertos.sh) points
# FREERTOS_DIR/FREERTOS_PORT at the patched NXP GCC/ARM_CR52_GIC port and
# enables src/s32z2_board_glue via S32_RTD_PATH.
function build_freertos_s32z2_nros() {
  build_freertos_nros s32z2 "S32Z2" actuation_s32z2_entry
}

# The EMULATED Cortex-R52 image (QEMU mps3-an536). Same CPU and kernel port as
# the S32Z2 image, but nothing is licensed or hardware-gated: the board bundle
# carries startup, GICv3, tick and the LAN9118 netif, so this image BOOTS:
#   qemu-system-arm -machine mps3-an536 -nographic \
#       -semihosting-config enable=on,target=native -kernel <image>
function build_freertos_an536_nros() {
  build_freertos_nros an536 "AN536 (emulated R52)" actuation_an536_entry
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
  freertos-posix-carla)
    build_freertos_posix_carla
    ;;
  freertos-s32z2)
    build_freertos_s32z2_nros
    ;;
  freertos-an536)
    build_freertos_an536_nros
    ;;
esac
