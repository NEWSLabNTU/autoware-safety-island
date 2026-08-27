#!/usr/bin/env bash
# Zephyr FVP runtime CI phases.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_ROOT="${ROOT_DIR}/build/zephyr-fvp"
LOG_DIR="${BUILD_ROOT}/logs"
FVP_BIN_NAME="FVP_BaseR_AEMv8R"
FVP_URL="https://developer.arm.com/-/cdn-downloads/permalink/FVPs-Architecture/FM-11.31/FVP_Base_AEMv8R_11.31_28_Linux_x86.tar.gz"
FVP_SHA256="627500afdb115701b412b85520e5c0e370b7f7e3f425f7ae4b1e8b14cbd4441a"
FVP_INSTALL_DIR="${BUILD_ROOT}/tools/fvp"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

mkdir -p "${LOG_DIR}"

ensure_fvp_available()
{
  local fvp_bin

  fvp_bin="$(command -v "${FVP_BIN_NAME}" || true)"
  if [ -n "${fvp_bin}" ]; then
    ARMFVP_BIN_PATH="$(dirname "${fvp_bin}")"
    export ARMFVP_BIN_PATH
    return
  fi

  if [ "$(uname -m)" != "x86_64" ]; then
    echo "${FVP_BIN_NAME} is available from Arm as a Linux x86 host binary only." >&2
    echo "Run Zephyr FVP validation on an amd64/x86_64 runner or devcontainer image." >&2
    exit 1
  fi

  echo "${FVP_BIN_NAME} not found; installing FVP from public ARM CDN..."
  mkdir -p "${FVP_INSTALL_DIR}"
  wget -q --show-progress --progress=bar:force:noscroll \
    "${FVP_URL}" -O "${BUILD_ROOT}/fvp.tar.gz"
  printf '%s  %s\n' "${FVP_SHA256}" "${BUILD_ROOT}/fvp.tar.gz" | sha256sum -c -
  tar -xzf "${BUILD_ROOT}/fvp.tar.gz" -C "${FVP_INSTALL_DIR}" --strip-components=1
  rm "${BUILD_ROOT}/fvp.tar.gz"

  if [ ! -x "${FVP_INSTALL_DIR}/bin/${FVP_BIN_NAME}" ]; then
    echo "Missing FVP binary after install: ${FVP_INSTALL_DIR}/bin/${FVP_BIN_NAME}" >&2
    exit 1
  fi

  export ARMFVP_BIN_PATH="${FVP_INSTALL_DIR}/bin"
}

ensure_fvp_available

# FVP run timeout
# 90 s stopped being enough: the image spends its first ~10 s in the DHCP
# initial-delay wait before `configure_network()` even runs, and the boot ahead
# of "Starting Controller Node" grew with the nano-ros pin. A too-tight window
# fails as a MISSING MARKER, which reads as a broken image rather than a slow
# one — the most expensive way to be wrong about this.
FVP_TIMEOUT_SECONDS="${FVP_TIMEOUT_SECONDS:-200}"

build_variant()
{
  local name="$1"
  shift

  "${ROOT_DIR}/build.sh" --platform zephyr-fvp -d "${BUILD_ROOT}/${name}" "$@"
}

# Run FVP with the built ELF and capture output
run_fvp_variant()
{
  local name="$1"
  local log="$2"
  local timeout_seconds="$3"

  local build_dir="${BUILD_ROOT}/${name}"
  if [ ! -f "${build_dir}/zephyr/zephyr.elf" ]; then
    echo "Missing ELF: ${build_dir}/zephyr/zephyr.elf" >&2
    exit 1
  fi

  # Remove old log
  rm -f "${log}"

  echo "Starting FVP for ${name}..."

  # Use west build --target run which uses CMake's FVP configuration
  # ARMFVP_BIN_PATH must be set for CMake to find the FVP binary
  set +e
  run_command_with_timeout "${log}" "${timeout_seconds}" \
    west build -d "${build_dir}" --target run
  local rc=$?
  set -e

  if [ ! -s "${log}" ]; then
    echo "FVP produced no output for ${name}" >&2
    exit 1
  fi

  echo "FVP ${name} finished"
}

# Every runtime phase asserts the absence of a fatal error as well as the
# presence of its markers. The images are long-lived and killed by timeout, so
# a crash does not change the exit code: a require_marker-only phase stays
# green straight through one, provided the marker printed first. That is
# exactly how a net_socket_service stack overflow went unnoticed here.
echo "Phase 1 - Zephyr FVP full controller build + runtime smoke"
build_variant full
run_fvp_variant full "${LOG_DIR}/controller.log" "${FVP_TIMEOUT_SECONDS}"
require_marker "${LOG_DIR}/controller.log" "Starting Controller Node"
require_marker "${LOG_DIR}/controller.log" "Controller Node Started"
require_marker "${LOG_DIR}/controller.log" "Actuation Safety Island is Live"
forbid_marker "${LOG_DIR}/controller.log" "ZEPHYR FATAL ERROR"

echo "Phase 2 - Zephyr FVP unit_test build + run"
build_variant unit --unit-test
run_fvp_variant unit "${LOG_DIR}/unit.log" "${FVP_TIMEOUT_SECONDS}"
require_marker "${LOG_DIR}/unit.log" "=== All Tests Passed ==="
forbid_marker "${LOG_DIR}/unit.log" "ZEPHYR FATAL ERROR"

echo "Phase 3 - Zephyr FVP DDS loopback build + run"
build_variant dds-loopback --dds-loopback-test
run_fvp_variant dds-loopback "${LOG_DIR}/dds-loopback.log" "${FVP_TIMEOUT_SECONDS}"
require_marker "${LOG_DIR}/dds-loopback.log" "Starting DDS loopback test"
require_marker "${LOG_DIR}/dds-loopback.log" "STEERING REPORT"
require_marker "${LOG_DIR}/dds-loopback.log" "DDS loopback test passed"
forbid_marker "${LOG_DIR}/dds-loopback.log" "ZEPHYR FATAL ERROR"

echo "Phase 4 - Zephyr FVP CAN loopback build + run"
build_variant can --can-output-test
run_fvp_variant can "${LOG_DIR}/can.log" "${FVP_TIMEOUT_SECONDS}"
require_marker "${LOG_DIR}/can.log" "CAN output tests passed"
forbid_marker "${LOG_DIR}/can.log" "ZEPHYR FATAL ERROR"

echo "Phase 5 - Zephyr FVP TAP network build smoke"
"${ROOT_DIR}/build.sh" --platform zephyr-fvp --network tap -d "${ROOT_DIR}/build/zephyr-fvp-tap"
test -f "${ROOT_DIR}/build/zephyr-fvp-tap/zephyr/zephyr.elf"

echo "Phase 6 - Zephyr FVP scheduling statistics (rt-eval Layer 1)"
# Kept separate from phase 3 rather than folded into it: if the statistics
# layer regresses, that should not be indistinguishable from a DDS-path
# regression. See docs/design/rt_evaluation_zephyr.rst.
build_variant stats --trace-stats --dds-loopback-test
run_fvp_variant stats "${LOG_DIR}/stats.log" "${FVP_TIMEOUT_SECONDS}"
# The workload must still pass with the statistics enabled — this phase is a
# non-regression check as much as a reporting one.
require_marker "${LOG_DIR}/stats.log" "DDS loopback test passed"
# A fatal error does not fail the run on its own, because the image is killed
# by timeout either way. Assert it explicitly: an overflowing stack in a
# reporting thread is exactly what this phase should catch.
forbid_marker "${LOG_DIR}/stats.log" "ZEPHYR FATAL ERROR"
# The per-thread block itself, and the CONFIG_SCHED_THREAD_USAGE_ANALYSIS
# fields that make it worth collecting.
require_marker "${LOG_DIR}/stats.log" "Thread analyze:"
require_marker "${LOG_DIR}/stats.log" "Total CPU cycles used"
require_marker "${LOG_DIR}/stats.log" "Longest Frame"
# Three stack overflows were found in this repo by reading this very report by
# eye — net_socket_service, main and asi_sntp_resync — and none of them printed
# a diagnostic. Assert on it so the fourth is caught without anyone looking.
# 85% is chosen against the measured figures: the healthy image's worst thread
# sits at 70%, and a thread reporting 100% is already overflowing (the analyzer
# clamps at the stack end, so its real requirement is unknown).
require_stack_headroom "${LOG_DIR}/stats.log" 85

echo "Zephyr FVP runtime validation OK"
