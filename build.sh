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
  echo -e "${GREEN}                         docs/design/rt_evaluation_zephyr.rst.${NC}"
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
# `nros sync` writes into it AFTER the CLI is built, so the stamp has already
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
  export NROS_MAX_PARAMETERS="${NROS_MAX_PARAMETERS:-256}"
  # Executor sizing (nros-node build.rs): the controller registers 5
  # subscriptions + timers + publishers (default MAX_CBS=4 → creation fails
  # with TransportError at boot), and /planning trajectories run 9-14 KiB
  # (default per-subscription RX buffer is 1 KiB). The arena would derive to
  # ~1 MB from MAX_CBS=16 x 16 KiB buffers (action-client worst case); cap
  # it at what this image actually needs.
  export NROS_EXECUTOR_MAX_CBS="${NROS_EXECUTOR_MAX_CBS:-16}"
  export NROS_SUBSCRIPTION_BUFFER_SIZE="${NROS_SUBSCRIPTION_BUFFER_SIZE:-16384}"
  export NROS_EXECUTOR_ARENA_SIZE="${NROS_EXECUTOR_ARENA_SIZE:-458752}"
  # Zephyr heap for the nros allocator funnel. nano-ros phase-391 W3 moved
  # Zephyr allocation onto an rlsf-backed funnel and turned COMMON_LIBC_MALLOC
  # OFF, which retires CONFIG_COMMON_LIBC_MALLOC_ARENA_SIZE — the 16 MiB arena
  # this image used to get. The funnel's own default is 64 KiB (sized for the
  # zenoh examples); Cyclone plus the MPC/PID controller need far more, and
  # without this the image hangs at boot on an allocation that never returns,
  # with every core parked in WFI.
  #
  # NECESSARY BUT NOT SUFFICIENT, measured: at pin ea592285e the lane still
  # hangs with this set, so something else in that wave also has to be sized or
  # configured. Kept because 64 KiB is unarguably wrong for this image and the
  # next person to attempt the bump should not have to rediscover the knob.
  # Inert at the current pin, which predates the funnel.
  export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-8388608}"

  # Application heap. nano-ros 60b4e0c1e ("the Zephyr funnel is rlsf-backed")
  # moved z_malloc AND __rust_alloc off Zephyr's kernel heap onto an rlsf arena
  # in nros-platform, sized by THIS env var (compile-time `option_env!`,
  # default 64 KiB).
  #
  # So `CONFIG_HEAP_MEM_POOL_SIZE` no longer governs application allocation.
  # It is still set to 4 MiB in the board conf, still looks authoritative, and
  # after that commit controls nothing on this path. Crossing it with the 64
  # KiB default hangs the image between "Network interfaces found: 1" and
  # "Starting Controller Node", with no fault, no log and no error code —
  # found by a 9-step bisect, filed as NEWSLabNTU/nano-ros#41.
  #
  # 4 MiB matches the figure phase 7 measured for this application; see
  # docs/roadmap/phase-7-realtime-evaluation.md W2. Keep the two in step: if
  # the heap requirement changes, BOTH this and the board conf's
  # CONFIG_HEAP_MEM_POOL_SIZE need looking at, since which one bites depends on
  # the nano-ros pin.
  #
  # This export only reaches cargo because the nano-ros pin now REGISTERS the
  # knob (`_nros_resolve_knob` in zephyr/cmake/nros_cargo_build.cmake). Before
  # that it was documented in the Rust source and absent from the generated
  # cargo command, so exporting it did nothing at all — verified by grepping
  # build.ninja, after several wrong diagnoses that each looked plausible.
  export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-4194304}"
  # ...and force cargo to actually honour it. `HEAP_SIZE` is read with
  # `option_env!`, which cargo bakes at compile time, but nros-platform has NO
  # build.rs and so emits no `cargo:rerun-if-env-changed=NROS_ZEPHYR_HEAP_SIZE`.
  # Cargo therefore does NOT invalidate on a change to this variable: an
  # already-built rlib is reused with the previous size compiled in, and the
  # image hangs exactly as if the variable had never been set.
  #
  # That is not hypothetical. It is why FVP CI kept failing after this export
  # landed: build.sh exported 4194304 (verified by probe), and the ELF still
  # carried a 0x10b38 (64 KiB) `zephyr_heap::HEAP` because the rlib was served
  # from cache. Standalone builds passed only because they happened to compile
  # it fresh.
  #

  # Pass the resolved host path of the `nros` CLI to CMake — the Zephyr module
  # resolves the codegen tool from `_NANO_ROS_CODEGEN_TOOL` (then $NROS_CLI,
  # then PATH); see modules/nros/zephyr/cmake/nros_generate_interfaces.cmake.
  local nros_codegen="${ROOT_DIR}/modules/nros/packages/cli/target/release/nros"

  # Build command with common arguments
  local build_args=(
    -DZEPHYR_TARGET="${ZEPHYR_TARGET}"
    # Name WHICH deploy this build is. The bringup carries four
    # ([deploy.fvp|freertos-posix|s32z2|an536]) and `nros ws board-facts`
    # refuses when several resolve differently — correct of it, but the cmake
    # wrapper then soft-skips and the image silently loses its board facts
    # (nano-ros issue 0755). Adding [deploy.an536] made the set ambiguous and
    # broke this lane exactly that way, so every lane now says which it is.
    # `fvp` for both Zephyr targets: the bringup declares one Zephyr deploy
    # and the S32Z board reuses it (there is no [deploy.s32z]).
    -DNROS_DEPLOY="fvp"
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
    extra_dtc_overlays+=("${ROOT_DIR}/actuation_module/boards/s32z270dc2_rtu0_r52@D.overlay")
  fi

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

  # Real-time evaluation profile (docs/design/rt_evaluation_zephyr.rst): CTF
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
  # Always run cargo (no-op when fresh; see the zephyr lane note).
  build_nros_cli "${nros_cli_manifest}"
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
    -DNROS_DEPLOY=freertos-posix \
    -DNROS_RMW=cyclonedds \
    -Dnano_ros_ROOT="${ROOT_DIR}/modules/nros" \
    -DNROS_CLI_BIN="${nros_cli_bin}" \
    -D_NANO_ROS_CODEGEN_TOOL="${nros_cli_bin}"
  cmake --build "${app_build_dir}" --target actuation_posix_entry -j"$(nproc)"
}

# The two ARMv8-R lanes — NXP S32Z270 hardware and QEMU mps3-an536 — differ in
# board name, entry target and whether an NXP SDK is involved. Everything else
# (CLI, ament env, cross toolchain discovery, kernel/port, sizing knobs, the
# cmake invocation) is identical, so it lives here once.
#
#   $1 board name        e.g. s32z270-freertos
#   $2 entry target      e.g. actuation_s32z2_entry
#   $3 human label       e.g. "S32Z2"
#   $4 deploy name       e.g. s32z2   (the [deploy.*] block in the bringup)
function build_freertos_armv8r_nros() {
  local board="$1"
  local entry_target="$2"
  local label="$3"
  local deploy="$4"
  echo -e "${GREEN}Building FreeRTOS ${label} runtime (nano-ros lane)...${NC}"
  if [ "${BUILD_TEST_FLAG}" != "0" ]; then
    echo -e "${RED}test programs are Zephyr-lane only; this lane builds the controller image${NC}" 1>&2
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

  # Cross toolchain: prefer the SDK-provisioned arm-none-eabi-gcc (13.2 —
  # what nano-ros builds and tests the s32z270 bundle with). The system
  # 10.3 rejects the entry codegen's C++ designated initializers. Newest
  # version first, matching nano-ros activate.sh; a system cross-gcc still
  # resolves when the store has none. Provision with:
  #   (cd modules/nros && nros setup --tool arm-none-eabi-gcc)
  local sdk_gcc_bin
  sdk_gcc_bin=$(find "${NROS_HOME:-$HOME/.nros}/sdk/arm-none-eabi-gcc" \
      -maxdepth 2 -type d -name bin 2>/dev/null | sort -Vr | head -1)
  if [ -n "${sdk_gcc_bin}" ] && [ -x "${sdk_gcc_bin}/arm-none-eabi-gcc" ]; then
    export PATH="${sdk_gcc_bin}:${PATH}"
  fi

  # Kernel: nros-pinned checkout by default (link-complete CRx_No_GIC port);
  # the NXP provisioning script overrides FREERTOS_DIR + FREERTOS_PORT.
  export FREERTOS_DIR="${FREERTOS_DIR:-${ROOT_DIR}/modules/nros/third-party/freertos/kernel}"
  export FREERTOS_PORT="${FREERTOS_PORT:-GCC/ARM_CRx_No_GIC}"
  if [ ! -d "${FREERTOS_DIR}/portable/${FREERTOS_PORT}" ]; then
    echo -e "${RED}FreeRTOS port missing at ${FREERTOS_DIR}/portable/${FREERTOS_PORT}.${NC}" 1>&2
    echo -e "${YELLOW}Default kernel: (cd modules/nros && ./packages/cli/target/release/nros setup --source freertos-kernel)${NC}" 1>&2
    echo -e "${YELLOW}NXP port: scripts/provision-nxp-freertos.sh${NC}" 1>&2
    exit 1
  fi

  # Same sizing knobs as the other nros lanes (environment wins).
  export NROS_MAX_PARAMETERS="${NROS_MAX_PARAMETERS:-256}"
  export NROS_EXECUTOR_MAX_CBS="${NROS_EXECUTOR_MAX_CBS:-16}"
  # 64 KiB, not the 16 KiB the other lanes use. A real Autoware trajectory
  # serialises to ~13 KiB and this lane talks to a real Autoware; at 16 KiB the
  # island reported NO trajectory at all while the same topic read a clean
  # 10 Hz on the host (the class nano-ros issue 0749 documents: an undersized
  # subscription buffer discards the sample silently, after Cyclone ACKed it).
  export NROS_SUBSCRIPTION_BUFFER_SIZE="${NROS_SUBSCRIPTION_BUFFER_SIZE:-65536}"

  local app_build_dir
  app_build_dir=$(realpath -m "${BUILD_DIR}")

  ( cd "${ROOT_DIR}/actuation_module" && "${nros_cli_bin}" sync . )

  # ROS domain. The bringup's `[deploy.<t>].domain_id` does NOT reach this lane:
  # nano-ros hardcodes the FreeRTOS app config's domain to 0 and the typed
  # path's runtime domain comes from the compile-time NROS_ENTRY_DOMAIN_ID,
  # which is fed by this cmake knob (nano-ros issue 0831). Default 0 keeps CI
  # as-is; the demo stack bridges Autoware (domain 1) to the island on domain 2,
  # so a demo build sets NROS_DOMAIN_ID=2.
  local _domain_arg=()
  if [ -n "${NROS_DOMAIN_ID:-}" ]; then
    _domain_arg=(-DNROS_DOMAIN_ID="${NROS_DOMAIN_ID}")
    echo -e "${GREEN}ROS domain ${NROS_DOMAIN_ID} (NROS_ENTRY_DOMAIN_ID)${NC}"
  fi

  cmake -S actuation_module -B "${app_build_dir}" \
    -DNANO_ROS_PLATFORM=freertos \
    -DNANO_ROS_BOARD="${board}" \
    -DNROS_DEPLOY="${deploy}" \
    "${_domain_arg[@]}" \
    -DNROS_RMW=cyclonedds \
    -DFREERTOS_PORT="${FREERTOS_PORT}" \
    -Dnano_ros_ROOT="${ROOT_DIR}/modules/nros" \
    -DNROS_CLI_BIN="${nros_cli_bin}" \
    -D_NANO_ROS_CODEGEN_TOOL="${nros_cli_bin}"
  cmake --build "${app_build_dir}" --target "${entry_target}" -j"$(nproc)"
}

# Phase 4 W5.b — the NXP S32Z270 lane. Without the NXP SDK the image
# LINK-COMPLETES against the bundle's in-tree GCC/ARM_CRx_No_GIC port and weak
# netif stubs; hardware provisioning (scripts/provision-nxp-freertos.sh) points
# FREERTOS_DIR/FREERTOS_PORT at the patched NXP GCC/ARM_CR52_GIC port and
# enables src/s32z2_board_glue via S32_RTD_PATH.
function build_freertos_s32z2_nros() {
  build_freertos_armv8r_nros s32z270-freertos actuation_s32z2_entry "S32Z2" s32z2
}

# Phase 6 A5 — the EMULATED Cortex-R52 lane (QEMU mps3-an536, nano-ros
# phase-385). Same CPU and kernel port as the S32Z2 lane above, but nothing is
# licensed or hardware-gated: the board bundle carries startup, GICv3, tick and
# the LAN9118 netif, so this image BOOTS. Run it with:
#   qemu-system-arm -machine mps3-an536 -nographic \
#       -semihosting-config enable=on,target=native -kernel <image>
function build_freertos_an536_nros() {
  build_freertos_armv8r_nros mps3-an536-freertos actuation_an536_entry "AN536 (emulated R52)" an536
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
