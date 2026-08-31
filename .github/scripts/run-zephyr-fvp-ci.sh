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

  # Honour an ARMFVP_BIN_PATH the caller already set (activate-asi.sh exports
  # one, and the licence-gated Arm download lands outside PATH). Without this
  # the `command -v` lookup below misses a perfectly good local FVP and the
  # CDN fallback re-downloads ~1 GB on every run.
  if [ -n "${ARMFVP_BIN_PATH:-}" ] && [ -x "${ARMFVP_BIN_PATH}/${FVP_BIN_NAME}" ]; then
    export ARMFVP_BIN_PATH
    return
  fi

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

# ---------------------------------------------------------------------------
# Cleanup on ANY exit, including abort.
#
# Without this the script's own death leaks whatever it had started. That is
# not hypothetical: a run killed mid-phase left an FVP running for ten hours
# on a core, because `set -e` and an outside SIGTERM both bypass the per-phase
# kill in run_fvp_variant.
#
# The sweep matches on the build path AND the ELF name. Matching the path
# alone would also select build.sh, west and cmake, and killing those is worse
# than the orphan it is trying to remove. Matching the binary NAME instead --
# `pkill -f FVP_BaseR_AEMv8R` -- is worse still: `-f` matches whole command
# lines, so it can select the very shell doing the killing.
# ---------------------------------------------------------------------------
CURRENT_FVP_PID=""

ci_cleanup()
{
  local rc=$?

  if [ -n "${CURRENT_FVP_PID}" ]; then
    kill -TERM -- "-${CURRENT_FVP_PID}" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-${CURRENT_FVP_PID}" 2>/dev/null || true
    CURRENT_FVP_PID=""
  fi

  if [ -n "${BG_PID}" ]; then
    kill -TERM "${BG_PID}" 2>/dev/null || true
    BG_PID=""
  fi

  local stray
  stray="$(ps -eo pid,args 2>/dev/null \
           | grep -F "${ROOT_DIR}/build/" \
           | grep -F 'zephyr.elf' \
           | grep -v ' grep ' \
           | awk '{print $1}')"
  if [ -n "${stray}" ]; then
    echo "cleanup: sweeping stray FVP pid(s): $(echo ${stray} | tr '\n' ' ')" >&2
    # shellcheck disable=SC2086
    kill -KILL ${stray} 2>/dev/null || true
  fi

  return "${rc}"
}
trap ci_cleanup EXIT INT TERM

# Build a variant in the BACKGROUND, so it overlaps the previous phase's model
# run. Phases are independent -- separate build dirs, separate logs -- and only
# ever one build is in flight at a time, so nothing contends for the cargo or
# ccache state. The win is bounded by min(build, run) per phase; it is a couple
# of minutes, not the fifteen that early-exit recovers.
BG_PID=""
BG_NAME=""
BG_LOG=""

build_variant_bg()
{
  local name="$1"
  shift
  BG_NAME="${name}"
  BG_LOG="${LOG_DIR}/build-${name}.log"
  "${ROOT_DIR}/build.sh" --platform zephyr-fvp -d "${BUILD_ROOT}/${name}" "$@" \
      >"${BG_LOG}" 2>&1 &
  BG_PID=$!
  echo "  (building ${name} in the background)"
}

# Join the background build. A failure here must be as loud as a foreground
# one, and must show its log -- a build that failed quietly in the background
# would otherwise surface as a confusing "Missing ELF" much later.
wait_build()
{
  [ -n "${BG_PID}" ] || return 0
  local pid="${BG_PID}"
  BG_PID=""
  if ! wait "${pid}"; then
    echo "Background build of ${BG_NAME} FAILED" >&2
    tail -40 "${BG_LOG}" >&2
    exit 1
  fi
}

# Run FVP with the built ELF and capture output
run_fvp_variant()
{
  local name="$1"
  local log="$2"
  local timeout_seconds="$3"
  shift 3
  # Remaining args are the markers that mean "this phase has done its work".
  # With none given the run waits out the full timeout, which is the old
  # behaviour.

  local build_dir="${BUILD_ROOT}/${name}"
  if [ ! -f "${build_dir}/zephyr/zephyr.elf" ]; then
    echo "Missing ELF: ${build_dir}/zephyr/zephyr.elf" >&2
    exit 1
  fi

  rm -f "${log}"
  echo "Starting FVP for ${name}..."

  # The image never exits on its own, so before this it was ALWAYS killed by
  # the clock: measured, a success marker landed 72 lines into a 762-line log
  # and the model then ran another ~190 s for nothing. Five runtime phases x
  # 200 s was ~17 minutes of pure waiting.
  #
  # `setsid` so the model gets its own process group and can be killed as a
  # group. Killing by name or by a path pattern is what leaked an FVP that
  # then burned a core for ten hours.
  setsid west build -d "${build_dir}" --target run >"${log}" 2>&1 &
  local wpid=$!
  CURRENT_FVP_PID="${wpid}"        # so ci_cleanup can reach it on abort

  local grace="${CI_FVP_GRACE_SECONDS:-15}"
  local waited=0
  local seen=0

  while [ "${waited}" -lt "${timeout_seconds}" ]; do
    kill -0 "${wpid}" 2>/dev/null || break      # model exited by itself

    if [ "$#" -gt 0 ]; then
      seen=1
      local m
      for m in "$@"; do
        grep -aqF -- "${m}" "${log}" 2>/dev/null || { seen=0; break; }
      done
      if [ "${seen}" = 1 ]; then
        # NOT an immediate kill. `forbid_marker "ZEPHYR FATAL ERROR"` exists
        # because a crash can land AFTER the success marker -- that is exactly
        # how a net_socket_service stack overflow went unnoticed here. Keep
        # watching for a grace window so the forbid checks still have
        # something to find.
        echo "  markers satisfied; ${grace}s grace, then stopping"
        sleep "${grace}"
        break
      fi
    fi

    sleep 2
    waited=$((waited + 2))
  done

  kill -TERM -- "-${wpid}" 2>/dev/null
  sleep 1
  kill -KILL -- "-${wpid}" 2>/dev/null
  wait "${wpid}" 2>/dev/null
  CURRENT_FVP_PID=""

  if [ ! -s "${log}" ]; then
    echo "FVP produced no output for ${name}" >&2
    exit 1
  fi

  echo "FVP ${name} finished after ~${waited}s"
}

# Every runtime phase asserts the absence of a fatal error as well as the
# presence of its markers. The images are long-lived and killed by timeout, so
# a crash does not change the exit code: a require_marker-only phase stays
# green straight through one, provided the marker printed first. That is
# exactly how a net_socket_service stack overflow went unnoticed here.
echo "Phase 1 - Zephyr FVP full controller build + runtime smoke"
build_variant full
build_variant_bg unit --unit-test          # overlaps phase 1's model run
run_fvp_variant full "${LOG_DIR}/controller.log" "${FVP_TIMEOUT_SECONDS}" \
    "Starting Controller Node" "Controller Node Started" \
    "Actuation Safety Island is Live"
require_marker "${LOG_DIR}/controller.log" "Starting Controller Node"
require_marker "${LOG_DIR}/controller.log" "Controller Node Started"
require_marker "${LOG_DIR}/controller.log" "Actuation Safety Island is Live"
forbid_marker "${LOG_DIR}/controller.log" "ZEPHYR FATAL ERROR"

echo "Phase 2 - Zephyr FVP unit_test build + run"
wait_build
build_variant_bg dds-loopback --dds-loopback-test
run_fvp_variant unit "${LOG_DIR}/unit.log" "${FVP_TIMEOUT_SECONDS}" \
    "=== All Tests Passed ==="
require_marker "${LOG_DIR}/unit.log" "=== All Tests Passed ==="
forbid_marker "${LOG_DIR}/unit.log" "ZEPHYR FATAL ERROR"

echo "Phase 3 - Zephyr FVP DDS loopback build + run"
wait_build
build_variant_bg can --can-output-test
run_fvp_variant dds-loopback "${LOG_DIR}/dds-loopback.log" "${FVP_TIMEOUT_SECONDS}" \
    "Starting DDS loopback test" "STEERING REPORT" "DDS loopback test passed"
require_marker "${LOG_DIR}/dds-loopback.log" "Starting DDS loopback test"
require_marker "${LOG_DIR}/dds-loopback.log" "STEERING REPORT"
require_marker "${LOG_DIR}/dds-loopback.log" "DDS loopback test passed"
forbid_marker "${LOG_DIR}/dds-loopback.log" "ZEPHYR FATAL ERROR"

echo "Phase 4 - Zephyr FVP CAN loopback build + run"
wait_build
build_variant_bg stats --trace-stats --dds-loopback-test
run_fvp_variant can "${LOG_DIR}/can.log" "${FVP_TIMEOUT_SECONDS}" \
    "CAN output tests passed"
require_marker "${LOG_DIR}/can.log" "CAN output tests passed"
forbid_marker "${LOG_DIR}/can.log" "ZEPHYR FATAL ERROR"

echo "Phase 5 - Zephyr FVP TAP network build smoke"
# Join the stats build BEFORE starting this one. Phase 5 is build-only, so
# without this the background stats build and this foreground TAP build would
# run concurrently -- breaking the one-build-at-a-time property the overlap
# scheme depends on for its cache behaviour.
wait_build
"${ROOT_DIR}/build.sh" --platform zephyr-fvp --network tap -d "${ROOT_DIR}/build/zephyr-fvp-tap"
test -f "${ROOT_DIR}/build/zephyr-fvp-tap/zephyr/zephyr.elf"

echo "Phase 6 - Zephyr FVP scheduling statistics (rt-eval Layer 1)"
# Kept separate from phase 3 rather than folded into it: if the statistics
# layer regresses, that should not be indistinguishable from a DDS-path
# regression. See docs/design/rt_evaluation_zephyr.rst.
# The stats build was started during phase 4 and joined in phase 5, so this
# is a no-op; kept so the phase reads correctly if phase 5 is ever removed.
wait_build
run_fvp_variant stats "${LOG_DIR}/stats.log" "${FVP_TIMEOUT_SECONDS}" \
    "DDS loopback test passed" "Thread analyze:" "Total CPU cycles used" \
    "Longest Frame"
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
