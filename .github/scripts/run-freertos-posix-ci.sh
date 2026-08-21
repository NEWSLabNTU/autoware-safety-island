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
log="${BUILD_ROOT}/controller.log"
rm -f "${log}"
set +e
NROS_ENTRY_SPIN_MS=8000 timeout --kill-after=10s 60s "${entry}" >"${log}" 2>&1
rc=$?
set -e
if ! is_success_or_timeout "${rc}"; then
  dump_log "${log}"
  echo "Entry exited unexpectedly: ${rc}" >&2
  exit "${rc}"
fi
require_marker "${log}" "Starting Controller Node"
require_marker "${log}" "Controller Node Started"
require_marker "${log}" "Actuation Safety Island is Live"
# Phase 4 (0745) — the bringup's seeded control_output (DDS_ONLY) drives the
# node; this marker asserts launch-param seeding works end-to-end. The CAN
# path is exercised by the Zephyr lane's can-output-test phase.
require_marker "${log}" "Control command output mode: DDS_ONLY"
require_marker "${log}" "Control is skipped since input data is not ready"
echo "Controller smoke OK: boot markers + control-loop spin observed"

echo "FreeRTOS POSIX (nano-ros) runtime validation OK"
