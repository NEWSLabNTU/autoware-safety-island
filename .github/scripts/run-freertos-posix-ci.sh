#!/usr/bin/env bash
# FreeRTOS POSIX runtime CI phases — nano-ros workspace lane (phase-4 W5.a).
#
# The legacy phases (unit/pub-sub/CAN test programs on the vendored
# CycloneDDS) retired with the lane; test programs are Zephyr-lane-only and
# covered by run-zephyr-fvp-ci.sh. This lane proves: the workspace build
# (nros sync + codegen + host CycloneDDS self-provision) and the runtime —
# board-owned FreeRTOS scheduler, controller task boot markers, CAN mock,
# control-loop spin — with a bounded self-exit.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_ROOT="${ROOT_DIR}/build/freertos-posix"
NROS="${ROOT_DIR}/modules/nros"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

cd "${ROOT_DIR}"

echo "Phase 0 - nano-ros provisioning (CLI, launch-resolve, FreeRTOS kernel)"
cargo build --release --manifest-path "${NROS}/packages/cli/Cargo.toml" -p nros-cli
cargo build --release \
  --manifest-path "${NROS}/packages/cli/nros-launch-resolve/Cargo.toml"
ln -sf "${NROS}/packages/cli/nros-launch-resolve/target/release/nros-launch-resolve" \
       "${NROS}/packages/cli/target/release/nros-launch-resolve"
( cd "${NROS}" && ./packages/cli/target/release/nros setup --source freertos-kernel )

echo "Phase 1 - FreeRTOS POSIX (nano-ros) controller build"
"${ROOT_DIR}/build.sh" --platform freertos-posix -d "${BUILD_ROOT}"

echo "Phase 2 - runtime smoke (bounded spin)"
entry="${BUILD_ROOT}/src/freertos_posix_entry/actuation_posix_entry"
test -x "${entry}"

# CycloneDDS on this lane links whatever the image supplies -- in the Autoware
# devcontainer that includes iceoryx -- and the LINKER finding a library says
# nothing about the LOADER finding it. CI died here with
#   error while loading shared libraries: libiceoryx_binding_c.so
# after a clean build and link. Put the prefixes' lib dirs on the run-time path.
#
# Shared with the Zephyr lane, which needs the same directories for a different
# reason -- see add_ros_lib_paths in ci-helpers.sh.
add_ros_lib_paths

log="${BUILD_ROOT}/controller.log"
rm -f "${log}"
set +e
NROS_ENTRY_SPIN_MS=8000 timeout --kill-after=10s 60s "${entry}" >"${log}" 2>&1
rc=$?
set -e
if ! is_success_or_timeout "${rc}"; then
  dump_log "${log}"
  echo "Entry exited unexpectedly: ${rc}" >&2
  # 127 from a binary that built and linked is a LOADER failure. Name the
  # unresolved libraries rather than leaving the next reader to guess.
  if [ "${rc}" = "127" ]; then
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset}" >&2
    ldd "${entry}" 2>&1 | grep "not found" >&2 || true
  fi
  exit "${rc}"
fi
require_marker "${log}" "Starting Controller Node"
require_marker "${log}" "Controller Node Started"
require_marker "${log}" "Actuation Safety Island is Live"
# Phase 4 (0745) — the bringup's seeded control_output (DDS_ONLY) drives the
# node; this marker asserts launch-param seeding works end-to-end. The CAN
# path is exercised by the Zephyr lane's can-output-test phase.
require_marker "${log}" "Control command output mode: DDS_ONLY"
# The control loop is spinning with no upstream Autoware to feed it, so it
# takes the not-ready path every cycle. Since the 2026-08-24 safety hardening
# that path COMMANDS A SAFE STOP rather than publishing nothing (silence let a
# stale command stay latched downstream) — this marker asserts both that the
# loop runs and that the fallback output path is the one it takes.
require_marker "${log}" "Inputs not ready — commanding safe stop"
echo "Controller smoke OK: boot markers + control-loop spin observed"

echo "FreeRTOS POSIX (nano-ros) runtime validation OK"
