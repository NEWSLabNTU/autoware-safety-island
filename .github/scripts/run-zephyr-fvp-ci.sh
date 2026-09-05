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

# The same nano-ros knobs build.sh resolves. `west build --target run` re-enters
# cmake, and a reconfigure without these picks the crate defaults -- a 64 KiB
# platform heap that cannot hold the 448 KiB executor arena -- so the lane
# failed AFTER a successful build, at the moment it tried to start the model.
# shellcheck source=../../scripts/zephyr-nros-knobs.sh
source "${ROOT_DIR}/scripts/zephyr-nros-knobs.sh"

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

# ...and the message prefixes, for the same reconfigure. Without them it dies on
# the first .msg it looks for: "nros_generate_interfaces(): cannot find
# 'msg/Odometry.msg' for package 'nav_msgs'".
#
# Three separate variables now, all one shape: `west build --target run`
# re-enters cmake, so whatever build.sh resolves, this script has to resolve
# identically. Each is defined once and sourced by both.
# shellcheck source=../../scripts/ament-env.sh
source "${ROOT_DIR}/scripts/ament-env.sh"
resolve_ament_env

# The rest of what build.sh puts around a Zephyr configure, for the same reason:
#   * CMAKE_PREFIX_PATH is CLEARED. Resolving the messages above may source a
#     ROS setup.bash, which sets it -- and a populated CMAKE_PREFIX_PATH lets
#     the cross build find host ROS packages. build.sh clears it deliberately;
#     a reconfigure here must not quietly reintroduce it.
#   * the host `nros` CLI is on PATH, since the Zephyr module resolves the
#     codegen tool from _NANO_ROS_CODEGEN_TOOL, then $NROS_CLI, then PATH.
export CMAKE_PREFIX_PATH=""
export NROS_REPO_DIR="${ROOT_DIR}/modules/nros"
export PATH="${ROOT_DIR}/modules/nros/packages/cli/target/release:${PATH}"

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

# There is no background build, and no cross-variant interleave.
#
# This lane used to build the NEXT variant while the CURRENT one ran, on the
# stated premise that "only ever one build is in flight at a time". Two things
# were wrong with that. `run_fvp_variant` starts the model with
# `west build --target run`, which RE-ENTERS the build graph -- so a run
# overlapped the background build. And serializing those builds did not fix it:
#
#   nros-cpp: .../nros_config_generated.h was written by another crate with
#   DIFFERENT probed sizes ... NROS_EXECUTOR_SIZE: on-disk=477088 vs
#   would-write=477336
#
# came back with the builds strictly ordered. The cause is not concurrency but
# the INTERLEAVE: building a differently-configured variant between another
# variant's build and its run leaves that variant's build.ninja stale, so the
# run reconfigures and re-probes, and nano-ros's size-probe state under
# modules/nros/build no longer matches the header the earlier build wrote.
#
# Each variant is now built immediately before it is run. Nothing is stale at
# run time, so `--target run` has nothing to rebuild -- which also retires a
# whole class of failure this lane kept hitting, where the reconfigure ran
# without the environment build.sh had established.
#
# BG_PID stays only for the cleanup trap, which kills a build if the job is
# interrupted mid-phase.
BG_PID=""

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
  # Through build.sh, NOT `west build --target run` directly: that command
  # re-enters the build graph, and nano-ros's size-probe identity is every
  # NROS_* variable in the environment plus $DOTCONFIG's CONFIG_NROS_* lines.
  # Launched from here the numbers differed from the build's and the C/C++
  # header guard stopped the run. Replicating the environment variable by
  # variable cannot converge; running from the same place the build ran can.
  setsid "${ROOT_DIR}/build.sh" --platform zephyr-fvp -t "${ZEPHYR_TARGET:-fvp_baser_aemv8r_smp}" \
      -d "${build_dir}" --run >"${log}" 2>&1 &
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
echo "Phase 0 - nano-ros launch resolver"
NROS="${ROOT_DIR}/modules/nros"
cargo build --release \
  --manifest-path "${NROS}/packages/cli/nros-launch-resolve/Cargo.toml"
mkdir -p "${NROS}/packages/cli/target/release"
ln -sf "${NROS}/packages/cli/nros-launch-resolve/target/release/nros-launch-resolve" \
       "${NROS}/packages/cli/target/release/nros-launch-resolve"

echo "Phase 1 - Zephyr FVP full controller build + runtime smoke"
build_variant full
run_fvp_variant full "${LOG_DIR}/controller.log" "${FVP_TIMEOUT_SECONDS}" \
    "Starting Controller Node" "Controller Node Started" \
    "Actuation Safety Island is Live"
require_marker "${LOG_DIR}/controller.log" "Starting Controller Node"
require_marker "${LOG_DIR}/controller.log" "Controller Node Started"
require_marker "${LOG_DIR}/controller.log" "Actuation Safety Island is Live"
forbid_marker "${LOG_DIR}/controller.log" "ZEPHYR FATAL ERROR"

echo "Phase 2 - Zephyr FVP unit_test build + run"
build_variant unit --unit-test
run_fvp_variant unit "${LOG_DIR}/unit.log" "${FVP_TIMEOUT_SECONDS}" \
    "=== All Tests Passed ==="
require_marker "${LOG_DIR}/unit.log" "=== All Tests Passed ==="
forbid_marker "${LOG_DIR}/unit.log" "ZEPHYR FATAL ERROR"

echo "Phase 3 - Zephyr FVP DDS loopback build + run"
build_variant dds-loopback --dds-loopback-test
run_fvp_variant dds-loopback "${LOG_DIR}/dds-loopback.log" "${FVP_TIMEOUT_SECONDS}" \
    "Starting DDS loopback test" "STEERING REPORT" "DDS loopback test passed"
require_marker "${LOG_DIR}/dds-loopback.log" "Starting DDS loopback test"
require_marker "${LOG_DIR}/dds-loopback.log" "STEERING REPORT"
require_marker "${LOG_DIR}/dds-loopback.log" "DDS loopback test passed"
forbid_marker "${LOG_DIR}/dds-loopback.log" "ZEPHYR FATAL ERROR"

echo "Phase 4 - Zephyr FVP CAN loopback build + run"
build_variant can --can-output-test
run_fvp_variant can "${LOG_DIR}/can.log" "${FVP_TIMEOUT_SECONDS}" \
    "CAN output tests passed"
require_marker "${LOG_DIR}/can.log" "CAN output tests passed"
forbid_marker "${LOG_DIR}/can.log" "ZEPHYR FATAL ERROR"

echo "Phase 5 - Zephyr FVP TAP network build smoke"
# Build-only phase; the variant it does not run is built where it IS run.
"${ROOT_DIR}/build.sh" --platform zephyr-fvp --network tap -d "${ROOT_DIR}/build/zephyr-fvp-tap"
test -f "${ROOT_DIR}/build/zephyr-fvp-tap/zephyr/zephyr.elf"

echo "Phase 6 - Zephyr FVP scheduling statistics (rt-eval Layer 1)"
# Kept separate from phase 3 rather than folded into it: if the statistics
# layer regresses, that should not be indistinguishable from a DDS-path
# regression. See docs/design/rt_evaluation_zephyr.rst.
# The stats build was started during phase 4 and joined in phase 5, so this
# is a no-op; kept so the phase reads correctly if phase 5 is ever removed.
build_variant stats --trace-stats --dds-loopback-test
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
