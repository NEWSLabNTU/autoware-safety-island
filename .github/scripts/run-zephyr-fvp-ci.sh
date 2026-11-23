#!/usr/bin/env bash
# Zephyr FVP runtime CI phases.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_ROOT="${ROOT_DIR}/build/zephyr-fvp"
LOG_DIR="${BUILD_ROOT}/logs"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

# `idlc` -- the CycloneDDS IDL compiler, a HOST tool this lane shells during
# cmake configure -- comes from the image's ROS prefix and links iceoryx, which
# the loader cannot find without this:
#
#   cached idlc /opt/ros/humble/bin/idlc cannot run (error while loading shared
#   libraries: libiceoryx_binding_c.so)
#
# nano-ros then reports it as "idlc not found", which is true of a tool that
# cannot execute, and misleading about why.
add_ros_lib_paths

# ...and the message prefixes (the devcontainer's Autoware install). Without
# them a configure dies on the first .msg it looks for: "nros_generate_interfaces():
# cannot find 'msg/Odometry.msg' for package 'nav_msgs'". `nros run` and the
# model-run phases re-enter the build (`west build -t run_armfvp`), so the
# environment is set once here, for every build and every run.
source_ament_env

# The rest of what build.sh puts around a Zephyr configure, for the same reason:
#   * CMAKE_PREFIX_PATH is CLEARED. Resolving the messages above may source a
#     ROS setup.bash, which sets it -- and a populated CMAKE_PREFIX_PATH lets
#     the cross build find host ROS packages. build.sh clears it deliberately;
#     a reconfigure here must not quietly reintroduce it.
#   * the host `nros` CLI is on PATH (nros_cli_select, Phase 0), since the
#     Zephyr module resolves the codegen tool from _NANO_ROS_CODEGEN_TOOL, then
#     $NROS_CLI, then PATH.
export CMAKE_PREFIX_PATH=""
export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"

mkdir -p "${LOG_DIR}"

# ---------------------------------------------------------------------------
# LOCKSTEP: actuation_module/west.yml's nano-ros revision must equal the
# modules/nros submodule pointer. west.yml says what a `west update` fetches;
# the submodule pointer says what a `git submodule update` checks out. When
# they disagree the two tools produce DIFFERENT trees from the same commit,
# and nothing in the build notices.
#
# This has now drifted twice. Once a pin was left pointing at a commit that a
# force-push had orphaned, and once a bump moved the submodule pointer without
# touching west.yml. Both were found by hand, long after the fact; the check
# costs a git call.
# ---------------------------------------------------------------------------
assert_pin_lockstep()
{
  local declared actual
  declared="$(sed -n '/name: nano-ros/,/path:/p' "${ROOT_DIR}/actuation_module/west.yml" \
              | sed -n 's/^ *revision: *//p' | head -1)"
  actual="$(git -C "${ROOT_DIR}" rev-parse HEAD:modules/nros 2>/dev/null)"

  if [ -z "${declared}" ] || [ -z "${actual}" ]; then
    echo "lockstep: could not read both pins (west.yml='${declared}' submodule='${actual}')" >&2
    exit 1
  fi
  if [ "${declared}" != "${actual}" ]; then
    echo "lockstep: nano-ros pin disagrees between west.yml and the submodule." >&2
    echo "  west.yml:  ${declared}" >&2
    echo "  submodule: ${actual}" >&2
    echo "west update and git submodule update would produce different trees." >&2
    echo "Move BOTH together; see the LOCKSTEP note in actuation_module/west.yml." >&2
    exit 1
  fi

  # A pin no branch contains is unfetchable for a fresh clone even when the
  # two agree -- which is how a rebased-away commit stayed pinned for a day.
  #
  # `branch -r` answers from remote-tracking refs, which a working checkout has
  # and a CI checkout may not: `west update` fetches the manifest revision and
  # nothing else, so refs/remotes/origin/* is EMPTY and every pin looks orphaned.
  # That is the false positive this guard hit the first time it ever ran in CI.
  # Fetch the heads before believing the answer; a genuinely orphaned commit is
  # still on no branch afterwards, so the check keeps its teeth.
  if [ -d "${ROOT_DIR}/modules/nros/.git" ] || [ -f "${ROOT_DIR}/modules/nros/.git" ]; then
    if ! git -C "${ROOT_DIR}/modules/nros" branch -r --contains "${actual}" 2>/dev/null | grep -q .; then
      # Not `origin`: west names the remote after the MANIFEST entry, so this
      # clone's only remote is `newslab`. Fetching `origin` there fails, which
      # is why the first attempt at this fix changed nothing in CI.
      local rmt
      for rmt in $(git -C "${ROOT_DIR}/modules/nros" remote); do
        git -C "${ROOT_DIR}/modules/nros" fetch --quiet "${rmt}" \
          "+refs/heads/*:refs/remotes/${rmt}/*" 2>/dev/null || true
      done
    fi
    if ! git -C "${ROOT_DIR}/modules/nros" branch -r --contains "${actual}" 2>/dev/null | grep -q .; then
      echo "lockstep: pin ${actual} is on no remote branch; a fresh clone cannot fetch it." >&2
      exit 1
    fi
  fi
  echo "lockstep: nano-ros pin ${actual} agrees and is reachable"
}
assert_pin_lockstep

ensure_fvp_available

# FVP run timeout
# 90 s stopped being enough: the image spends its first ~10 s in the DHCP
# initial-delay wait before `configure_network()` even runs, and the boot ahead
# of "Starting Controller Node" grew with the nano-ros pin. A too-tight window
# fails as a MISSING MARKER, which reads as a broken image rather than a slow
# one — the most expensive way to be wrong about this.
FVP_TIMEOUT_SECONDS="${FVP_TIMEOUT_SECONDS:-200}"

# ---------------------------------------------------------------------------
# Cleanup on ANY exit, including abort.
#
# `nros run` stops the model it started when it exits, but not when this
# script is killed under it: a run killed mid-phase once left an FVP running
# for ten hours on a core. Sweep what is left.
#
# The sweep matches on the build path AND the ELF name. Matching the path
# alone would also select west and cmake, and killing those is worse than the
# orphan it is trying to remove. Matching the binary NAME instead --
# `pkill -f FVP_BaseR_AEMv8R` -- is worse still: `-f` matches whole command
# lines, so it can select the very shell doing the killing.
# ---------------------------------------------------------------------------
ci_cleanup()
{
  local rc=$?

  # `|| true` because FINDING NOTHING is the good case, and it is a failure
  # status: grep exits 1 on no match, `pipefail` promotes that over awk's 0, and
  # `set -e` then aborts the trap -- which is the script's exit status.
  local stray
  stray="$(ps -eo pid,args 2>/dev/null \
           | grep -F "${ROOT_DIR}/" \
           | grep -F 'zephyr.elf' \
           | grep -F 'FVP_' \
           | grep -v ' grep ' \
           | awk '{print $1}')" || true
  if [ -n "${stray}" ]; then
    echo "cleanup: sweeping stray FVP pid(s): $(echo ${stray} | tr '\n' ' ')" >&2
    # shellcheck disable=SC2086
    kill -KILL ${stray} 2>/dev/null || true
  fi

  return "${rc}"
}
trap ci_cleanup EXIT INT TERM

# Phase 0 - the launch resolver, which build.sh's bootstrap hook does NOT build.
#
# `nros codegen entry` resolves the bringup's SystemModel by shelling
# `nros-launch-resolve`, and stops the cmake configure when it is absent:
#
#   resolve SystemModel for .../config/system_model.yaml: cannot resolve the
#   SystemModel: `nros-launch-resolve` not found
#
# The FreeRTOS lanes have always built it in their own Phase 0; this lane
# reached the same code only once its earlier failures were cleared.
echo "Phase 0 - nano-ros CLI and launch resolver"
NROS="${ROOT_DIR}/modules/nros"
# The CLI is needed here first for the corrosion provisioning, which the
# `nros configure` metadata probe uses; build.sh selects the same one.
nros_cli_select
# Corrosion (the CMake road's Rust bridge) comes from the SDK store and a
# configure no longer fetches it (nano-ros RFC-0104 D10). Provisioned from the
# workspace root so actuation_module/nros-sdk.lock governs the version.
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" setup "${NROS_SETUP_INDEX_ARGS[@]}" --tool corrosion )

# nano-ros's Zephyr 3.7 patch set, applied to this west workspace (zephyr/ and
# modules/lang/rust). Since nano-ros 0a4cfcc063 a Rust image refuses to
# configure when zephyr-lang-rust lacks its hunks ("missing nano-ros patch
# hunks": board facts, issue 2185; staticlib-only LTO, issue 2407). This is
# step (b) of `nros setup board fvp-aemv8r-smp`, which bootstrap-asi.sh runs
# on a local host; the other steps are already covered here. Idempotent, so a
# cached workspace is fine.
bash "${NROS}/scripts/zephyr/patches/3.7.sh" "${ROOT_DIR}"

# This repo's Zephyr patches (patches/zephyr), as build.sh applies them before
# every Zephyr build; the images below are built by nros directly.
"${ROOT_DIR}/scripts/apply-zephyr-patches.sh" "${ROOT_DIR}/zephyr"

# The controller image and the test program images run with
# `nros run <image> --expect <line>... --forbid <line> --timeout N`: nros
# builds the image if stale and boots it on the board's runner (the FVP model
# through Zephyr's run_armfvp target, with the board's and the image's model
# parameters), passes once every --expect line has appeared on the console
# (exit 1 when the timeout passes first) and fails on the first --forbid line,
# before or after the expectation is met. Nothing here starts the model or
# greps its output; each run's console is teed into ${LOG_DIR} for the job's
# artifact. The FVP is user-provided (ensure_fvp_available,
# ARMFVP_BIN_PATH).
#
# Every phase forbids "ZEPHYR FATAL ERROR": the images are long-lived, so a
# crash after the success line changes nothing else. That is exactly how a
# net_socket_service stack overflow went unnoticed here. --settle keeps
# watching for that long after the last --expect line, for a crash or the
# rest of a report.
#
# The west workspace is this checkout, for nros build and for the build
# `nros run` starts when an image is stale: nros takes the nearest .west/
# whose manifest lists zephyr (nano-ros issue 2877), ahead of the store's
# Zephyr workspace, which has neither this repo's Zephyr patches nor, in CI,
# a checkout at all. The build prints the tree it chose.
FATAL="ZEPHYR FATAL ERROR"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
nros_fvp()
{
  local verb="$1"
  shift
  ( cd "${ROOT_DIR}/actuation_module" && \
      "${NROS_CLI}" "${verb}" "$@" )
}

echo "Phase 1 - Zephyr FVP controller image (nros run controller_bringup:fvp)"
nros_fvp build controller_bringup:fvp
# [tasks.control.zephyr] priority = 9 reached `main`, the boot sched task's
# thread: nano-ros reads the priority back after k_thread_priority_set(), which
# Zephyr 3.7 does not trace (nano-ros PR 3705).
nros_fvp run controller_bringup:fvp --timeout "${FVP_TIMEOUT_SECONDS}" \
    --expect "Starting Controller Node" \
    --expect "Controller Node Started" \
    --expect "Actuation Safety Island is Live" \
    --expect "nros: sched task priority set sched_task=\`control\` prio=9" \
    --forbid "${FATAL}" --settle "${SETTLE_SECONDS}" | tee "${LOG_DIR}/controller.log"

# The test programs (actuation_module/test), each an image of its own
# (src/test_bringup) whose entry is a Zephyr west application over the same
# source the FreeRTOS images build (src/asi_tests/asi_<program>_zephyr).
echo "Phase 2 - Zephyr FVP unit test image (nros run unit_test_bringup:fvp-aemv8r-smp)"
nros_fvp build unit_test_bringup:fvp-aemv8r-smp
nros_fvp run unit_test_bringup:fvp-aemv8r-smp --timeout "${FVP_TIMEOUT_SECONDS}" \
    --expect "=== All Tests Passed ===" \
    --forbid "${FATAL}" | tee "${LOG_DIR}/unit_test.log"

echo "Phase 3 - Zephyr FVP DDS loopback test image (nros run dds_loopback_test_bringup:fvp-aemv8r-smp)"
nros_fvp build dds_loopback_test_bringup:fvp-aemv8r-smp
nros_fvp run dds_loopback_test_bringup:fvp-aemv8r-smp --timeout "${FVP_TIMEOUT_SECONDS}" \
    --expect "Starting DDS loopback test" \
    --expect "STEERING REPORT" \
    --expect "DDS loopback test passed" \
    --forbid "${FATAL}" | tee "${LOG_DIR}/dds_loopback.log"

# The CAN output test on the CAN loopback device: a Zephyr-only image
# (src/test_bringup/can_output_test).
echo "Phase 4 - Zephyr FVP CAN output test image (nros run can_output_test_bringup:fvp-aemv8r-smp)"
nros_fvp build can_output_test_bringup:fvp-aemv8r-smp
nros_fvp run can_output_test_bringup:fvp-aemv8r-smp --timeout "${FVP_TIMEOUT_SECONDS}" \
    --expect "CAN output tests passed" \
    --forbid "${FATAL}" --settle "${SETTLE_SECONDS}" | tee "${LOG_DIR}/can.log"

echo "Phase 5 - Zephyr FVP TAP network build smoke"
"${ROOT_DIR}/build.sh" --platform zephyr-fvp --network tap -d "${ROOT_DIR}/build/zephyr-fvp-tap"
test -f "${ROOT_DIR}/build/zephyr-fvp-tap/zephyr/zephyr.elf"

echo "Phase 6 - Zephyr FVP scheduling statistics (rt-eval Layer 1)"
# Kept separate from phase 3 rather than folded into it: if the statistics
# layer regresses, that should not be indistinguishable from a DDS-path
# regression. See documentation/design/rt_evaluation_zephyr.rst. The image is
# the loopback test with the thread-analyzer fragment
# (dds_loopback_test_bringup:fvp-aemv8r-smp-stats). The workload must still
# pass with the statistics enabled, and the run settles after the last
# --expect line so the console holds the whole report for the stack check.
nros_fvp build dds_loopback_test_bringup:fvp-aemv8r-smp-stats
nros_fvp run dds_loopback_test_bringup:fvp-aemv8r-smp-stats --timeout "${FVP_TIMEOUT_SECONDS}" \
    --expect "DDS loopback test passed" \
    --expect "Thread analyze:" \
    --expect "Total CPU cycles used" \
    --expect "Longest Frame" \
    --forbid "${FATAL}" --settle "${SETTLE_SECONDS}" | tee "${LOG_DIR}/stats.log"
# Three stack overflows were found in this repo by reading this very report by
# eye -- net_socket_service, main and asi_sntp_resync -- and none of them printed
# a diagnostic. Assert on it so the fourth is caught without anyone looking.
# 85% is chosen against the measured figures: the healthy image's worst thread
# sits at 70%, and a thread reporting 100% is already overflowing (the analyzer
# clamps at the stack end, so its real requirement is unknown).
require_stack_headroom "${LOG_DIR}/stats.log" 85

echo "Zephyr FVP runtime validation OK"
