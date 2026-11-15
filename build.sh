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
RUNTIME_TARGET_LIST=("zephyr-fvp" "zephyr-s32z" "freertos-posix" "freertos-s32z2" "freertos-an536")
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
# Build the in-tree nros CLI, and decide honestly whether its staleness gate
# applies to us.
#
# The gate compares a SOURCE STAMP embedded at build time against one recomputed
# at use time, over `cli-source-dirs.txt` plus all of packages/cli. It exists to
# stop a nano-ros DEVELOPER running a CLI older than sources they just edited.
#
# It misfires on a CONSUMER, because our own build mutates the stamped tree:
# `nros configure` writes into it AFTER the CLI is built, so the stamp has already
# moved by the time codegen checks it. Neither `cargo build` nor
# `cargo clean -p nros-cli` fixes that — both were measured, and both still end
# in "in-tree nros CLI is STALE" (it is what broke the FVP demo immediately
# after the 2026-08-29 pin move, presenting as a build failure with no clue).
#
# So: skip the gate ONLY when modules/nros is CLEAN, which is exactly the case
# the gate cannot be protecting — we are consuming a pinned upstream and have
# edited nothing. If the submodule is dirty, someone IS developing nano-ros
# here, the gate is doing its job, and we leave it alone.
function build_nros_cli() {
  local manifest="$1"
  echo -e "${GREEN}Building host nros CLI...${NC}"
  cargo build --release --manifest-path "${manifest}" -p nros-cli

  if [ -z "$(git -C "${ROOT_DIR}/modules/nros" status --porcelain 2>/dev/null)" ]; then
    export NROS_SKIP_STALE_CHECK=1
  else
    echo -e "${YELLOW}modules/nros has local changes — leaving the CLI staleness gate ON.${NC}"
  fi
}

# Message-source resolution (AMENT_PREFIX_PATH). Sourced rather than inline so
# the FVP CI script resolves the SAME prefixes before `west build --target run`
# re-enters cmake.
# shellcheck source=scripts/ament-env.sh
. "${ROOT_DIR}/scripts/ament-env.sh"

# --run: start the model for an ALREADY-BUILT -d directory. Needs only the
# build dir and ARMFVP_BIN_PATH, so it runs BEFORE anything that touches
# cargo. It used to run after build_nros_cli, and that "~0.1 s no-op" waits
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

function build_zephyr_actuation_module() {
  echo -e "${GREEN}Building Zephyr Actuation Module (nano-ros)...${NC}"
  # Phase 3 W1 (nano-ros branch) — the Zephyr platforms run on nano-ros:
  # messages come from nano-ros codegen (host `nros` CLI) and the
  # RMW is the nano-ros Zephyr module, so the vendored-CycloneDDS host tooling
  # upstream's Zephyr path used (idlc PATH + -DCYCLONEDDS_SRC) is not needed
  # here. The FreeRTOS platforms below still use it unchanged.
  require_nros_checkout
  if [ "${ZEPHYR_RUN_ONLY:-0}" = "1" ]; then
    run_zephyr_model
    return
  fi
  # Build the host `nros` CLI if missing or stale (full host provisioning is
  # scripts/bootstrap-asi.sh; this only ensures the CLI binary). Phase 3 W2.c
  # — inlined from the retired bootstrap-nano-ros-shim.sh.
  local nros_cli_manifest="${ROOT_DIR}/modules/nros/packages/cli/Cargo.toml"
  local nros_cli_bin="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"
  if [ ! -f "${nros_cli_manifest}" ]; then
    echo -e "${RED}nano-ros CLI manifest missing (${nros_cli_manifest}) — bump the west.yml nano-ros revision.${NC}" 1>&2
    exit 1
  fi
  # Always run cargo: a fresh CLI is a ~0.1 s no-op, and any partial check
  # misses part of the CLI's real input closure (its own source stamp hashes
  # the cli-source-dirs.txt dirs OUTSIDE packages/cli too — an mtime probe on
  # packages/cli alone let a pin bump through to a "CLI is STALE" codegen
  # failure, 2026-08-23).
  build_nros_cli "${nros_cli_manifest}"
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
  # The SystemModel nano_ros_entry reads is a build artifact only `nros configure`
  # writes; since nano-ros issue 1575 a configure without it is refused, not
  # silently tierless. Same step the FreeRTOS lanes run.
  ( cd "${ROOT_DIR}/actuation_module" && "${nros_cli_bin}" configure . )
  local extra_conf_files=()
  # EXTRA_DTC_OVERLAY_FILE is a single cmake variable, so every overlay the
  # lane wants has to be collected and passed as one ';'-separated list —
  # a second -D would silently drop the first.
  local extra_dtc_overlays=()

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
  # ZEPHYR LANE NOTE (nano-ros issues 0749/0756): these knobs reach the
  # Zephyr Rust lane only since nano-ros d1c5b3b3b (before that the curated
  # cargo env dropped them and every Zephyr image silently built the crate
  # defaults). 256 used to HANG boot right after dds_create_participant —
  # the param store was constructed on a task stack (~8.5 KiB/slot, issue
  # 0756) — fixed upstream at pin ba9dba805; unpinned back to 256 so all
  # ~150 controller parameters get declared slots.
  # nano-ros build knobs (parameter pool, executor sizing, the Zephyr heap
  # funnel). Sourced rather than inline so the FVP CI script can resolve the
  # SAME values before `west build --target run` re-enters cmake.
  # The S32Z270 heap. The knobs' 8 MiB default is sized on the 64-bit FVP and
  # does not build here: the R52 is 32-bit, so nano-ros's rlsf heap holds at
  # most 4 MiB ("heap size exceeds rlsf MAX_POOL_SIZE", MAX_POOL = 1 << (4 +
  # FLLEN 18)), and the image has to fit the 7 MiB SRAM the board overlay
  # selects. 2 MiB is 3.4x the peak the same controller reaches on the
  # emulated R52 (mps3-an536: 618,880 B with Cyclone).
  if [ "${ZEPHYR_TARGET}" = "s32z270dc2_rtu0_r52@D" ]; then
    export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-2097152}"
  fi
  # shellcheck source=scripts/zephyr-nros-knobs.sh
  . "${ROOT_DIR}/scripts/zephyr-nros-knobs.sh"
  # Pass the resolved host path of the `nros` CLI to CMake — the Zephyr module
  # resolves the codegen tool from `_NANO_ROS_CODEGEN_TOOL` (then $NROS_CLI,
  # then PATH); see modules/nros/zephyr/cmake/nros_generate_interfaces.cmake.
  local nros_codegen="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"

  # The bringup image this build is: [image.fvp], or [image.fvp-tap] (domain 2)
  # for the TAP network profile.
  local zephyr_image="fvp"
  if [ "${NETWORK_PROFILE}" = "tap" ]; then
    zephyr_image="fvp-tap"
  fi
  # The S32Z270 target is its own image, on this workspace's own board
  # (src/s32z270_zephyr_board): the FVP image's board states the FVP's
  # hardware and its AArch64 Rust triple.
  if [ "${ZEPHYR_TARGET}" = "s32z270dc2_rtu0_r52@D" ]; then
    zephyr_image="s32z"
    # The board package is not in the nano-ros tree; the nros CLI calls of the
    # configure that run outside this workspace find it through this path.
    export NROS_EXTRA_BOARD_PATH="${ROOT_DIR}/actuation_module/src/s32z270_zephyr_board${NROS_EXTRA_BOARD_PATH:+:${NROS_EXTRA_BOARD_PATH}}"
  fi

  # Build command with common arguments
  local build_args=(
    -DZEPHYR_TARGET="${ZEPHYR_TARGET}"
    # Name WHICH deploy this build is. The bringup carries four
    # ([deploy.fvp|freertos-posix|s32z2|an536]) and `nros ws board-facts`
    # refuses when several resolve differently — correct of it, but the cmake
    # wrapper then soft-skips and the image silently loses its board facts
    # (nano-ros issue 0755). Adding [deploy.an536] made the set ambiguous and
    # broke this lane exactly that way, so every lane now says which it is.
    # `fvp` (or `fvp-tap`) for the FVP and `s32z` for the S32Z270 target.
    -DNROS_DEPLOY="${zephyr_image}"
    -D_NANO_ROS_CODEGEN_TOOL="${nros_codegen}"
    -DEXTRA_CFLAGS="-Wno-error"
    -DEXTRA_CXXFLAGS="-Wno-error"
    "-DBUILD_TEST=${BUILD_TEST_FLAG}"
    # Issue 0745 — the bringup declares [system].features=["param_services"]
    # (launch-param seeding); the Zephyr module lane has no bringup-driven
    # capability resolution yet, so mirror it explicitly.
    -DNROS_FEATURES="param_services"
  )

  # nano-ros 0a4cfcc063 (phase-530 W4): the Zephyr module hook runs
  # `nros configure` for the image this west build is, before Kconfig, and
  # seeds every reader from its answer. The controller image is the bringup's
  # [image.fvp], so it names the bringup and the image; without them the
  # inventory is composed after its readers ran and the promise check refuses
  # the configure. The test images (--unit-test, --dds-*, --can-output-test)
  # are hand-written mains that are not the bringup's image, so they stay
  # guests and name neither.
  if [ "${BUILD_TEST_FLAG}" = "0" ]; then
    build_args+=(
      -DNROS_IMAGE_SYSTEM_DIR="${ROOT_DIR}/actuation_module/src/controller_bringup"
      -DNROS_IMAGE="${zephyr_image}"
    )
  fi

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

  # The S32Z270's devicetree (the 7 MiB SRAM2 as zephyr,sram, the ENETC MAC,
  # the ARM Automotive Kit's uart9 / PHY / CAN) is the board package's own
  # overlay (src/s32z270_zephyr_board/boards/), which nano_ros_use_board()
  # appends.

  local can_loopback_conf="${ROOT_DIR}/actuation_module/boards/${conf_base}_can_loopback.conf"
  local can_loopback_overlay="${ROOT_DIR}/actuation_module/boards/${conf_base}_can_loopback.overlay"
  if [ "${BUILD_TEST_FLAG}" = "4" ]; then
    if [ -f "${can_loopback_conf}" ]; then
      extra_conf_files+=("${can_loopback_conf}")
    fi
    if [ -f "${can_loopback_overlay}" ]; then
      extra_dtc_overlays+=("${can_loopback_overlay}")
    fi
  fi

  # Real-time evaluation profile (documentation/design/rt_evaluation_zephyr.rst): CTF
  # task timeline + thread runtime stats, streamed to uart1 so the console on
  # uart0 stays clean. The tracing buffer is irq_lock-protected only, which is
  # safe solely because prj_actuation.conf pins CONFIG_SMP=n.
  # Layer 1 on its own: scheduling statistics, no CTF. Cheap enough for CI,
  # and separable so the two layers can be bisected independently.
  if [ "${TRACE_STATS_ENABLED}" = "1" ] || [ "${TRACE_ENABLED}" = "1" ]; then
    extra_conf_files+=("${ROOT_DIR}/actuation_module/tracing_stats.conf")
  fi

  if [ "${TRACE_ENABLED}" = "1" ]; then
    local tracing_conf="${ROOT_DIR}/actuation_module/tracing.conf"
    local tracing_overlay="${ROOT_DIR}/actuation_module/boards/${conf_base}_tracing.overlay"
    if [ ! -f "${tracing_overlay}" ]; then
      echo -e "${RED}--trace has no uart overlay for ${conf_base}; supported on the FVP board only.${NC}" 1>&2
      exit 1
    fi
    extra_conf_files+=("${tracing_conf}")
    # AFTER tracing.conf, because it must override CONFIG_TRACING_BACKEND_UART.
    # Zephyr selects the backend with an #elif chain that tests UART first, so
    # leaving it enabled silently wins and the ring is never chosen.
    if [ "${TRACE_RING_ENABLED}" = "1" ]; then
      extra_conf_files+=("${ROOT_DIR}/actuation_module/tracing_ring.conf")
    fi
    extra_dtc_overlays+=("${tracing_overlay}")
    # -d may be given as either a relative or an absolute path, so resolve
    # rather than prefixing ROOT_DIR blindly.
    local trace_out="${TRACE_OUT_FILE:-$(realpath -m "${BUILD_DIR}")/trace.ctf}"
    mkdir -p "$(dirname "${trace_out}")"
    # board.cmake aims every FVP PL011 at stdout (out_file=-); send uart1 to a
    # file instead so the CTF octet stream is not interleaved with the console.
    # armfvp.cmake reads ARMFVP_EXTRA_FLAGS from the environment at CONFIGURE
    # time and bakes it into the `run` target, so exporting it here is what
    # makes a later `west build --target run` pick it up.
    export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS:-} -C bp.pl011_uart1.out_file=${trace_out}"
    echo -e "${GREEN}Tracing enabled: CTF stream -> ${trace_out}${NC}"
  fi

  if [ "${#extra_conf_files[@]}" -gt 0 ]; then
    local extra_conf_file
    extra_conf_file=$(IFS=';'; echo "${extra_conf_files[*]}")
    build_args+=(-DEXTRA_CONF_FILE="${extra_conf_file}")
  fi

  if [ "${#extra_dtc_overlays[@]}" -gt 0 ]; then
    local extra_dtc_overlay
    extra_dtc_overlay=$(IFS=';'; echo "${extra_dtc_overlays[*]}")
    build_args+=(-DEXTRA_DTC_OVERLAY_FILE="${extra_dtc_overlay}")
  fi

  # --run: start the model WITHOUT re-entering the build graph.
  #
  # `west build --target run` rebuilds first, and that rebuild cannot be made
  # to succeed from here. Measured, in a clean build dir, build then run:
  #
  #   nros-cpp: nros_config_generated.h was written by another crate with
  #   DIFFERENT probed sizes ... NROS_EXECUTOR_SIZE: on-disk=477088 vs
  #   would-write=477336
  #
  # The two numbers come from two nros-c compilations that coexist in one build
  # dir with different feature sets -- their own generated headers say so:
  #
  #   NROS_CONFIG_VARIANT "alloc_..._param_services_platform_zephyr_..."  -> 477336
  #   NROS_CONFIG_VARIANT "critical_section_..._platform_zephyr_..."      -> 477088
  #
  # and both write the SAME shared header. Whichever build script runs second
  # trips nano-ros's C/C++ agreement guard. The guard is right; what it catches
  # is upstream, and it is reached on any second cargo invocation because the
  # writer declares `rerun-if-changed` on the header it writes.
  #
  # So do not invoke cargo again to start a model that is already built. CMake
  # records the FVP command line in build.ninja; run exactly that.

  west build -p auto -d "${BUILD_DIR}" -b "${board_id}" actuation_module/ -- "${build_args[@]}"
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
  if [ "${BUILD_TEST_FLAG}" != "0" ]; then
    echo -e "${RED}test programs are Zephyr-lane only; this lane builds the controller image${NC}" 1>&2
    exit 1
  fi
  # The domain is the image's ([image.<id>] domain_id), rendered into the
  # generated entry. The old override would now be silently ignored.
  if [ -n "${NROS_DOMAIN_ID:-}" ]; then
    echo -e "${RED}NROS_DOMAIN_ID is no longer read: the domain is [image.${image}] domain_id in actuation_module/src/controller_bringup/system.toml.${NC}" 1>&2
    exit 1
  fi

  require_nros_checkout
  local nros_cli_manifest="${ROOT_DIR}/modules/nros/packages/cli/Cargo.toml"
  local nros_cli_bin="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"
  # Always run cargo (no-op when fresh; see the zephyr lane note).
  build_nros_cli "${nros_cli_manifest}"
  export CMAKE_PREFIX_PATH=""
  resolve_ament_env
  export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"
  export PATH="$(dirname "${nros_cli_bin}"):${PATH}"

  # Cross toolchain (the ARMv8-R boards): prefer the SDK-provisioned
  # arm-none-eabi-gcc (13.2 -- what nano-ros builds and tests these boards with). The system 10.3
  # rejects the entry codegen's C++ designated initializers. Provision with:
  #   (cd modules/nros && nros setup --tool arm-none-eabi-gcc)
  local sdk_gcc_bin
  sdk_gcc_bin=$(find "${NROS_HOME:-$HOME/.nros}/sdk/arm-none-eabi-gcc" \
      -maxdepth 2 -type d -name bin 2>/dev/null | sort -Vr | head -1)
  if [ -n "${sdk_gcc_bin}" ] && [ -x "${sdk_gcc_bin}/arm-none-eabi-gcc" ]; then
    export PATH="${sdk_gcc_bin}:${PATH}"
  fi

  # Native arguments to the CMake configure nros build drives.
  #
  # RelWithDebInfo (-O2 -g), the profile these images were always built with;
  # nros build's CMake road defaults to Release (-O3, ~130 KB more text on
  # an536), and `[image.<id>] profile` reaches only the cargo road (nano-ros
  # issue 3899).
  local native=(-DCMAKE_BUILD_TYPE=RelWithDebInfo)
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
}

# The FreeRTOS POSIX simulator: a host process, board-owned main() and
# scheduler, the node as a FreeRTOS task over host CycloneDDS.
function build_freertos_posix() {
  build_freertos_nros freertos-posix "POSIX" actuation_posix_entry
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
  freertos-s32z2)
    build_freertos_s32z2_nros
    ;;
  freertos-an536)
    build_freertos_an536_nros
    ;;
esac
