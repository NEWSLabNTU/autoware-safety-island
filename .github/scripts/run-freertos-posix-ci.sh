#!/usr/bin/env bash
# FreeRTOS POSIX runtime CI phases — nano-ros workspace lane (phase-4 W5.a).
#
# The legacy phases (unit/pub-sub/CAN test programs on the vendored
# CycloneDDS) retired with the lane; test programs are Zephyr-lane-only and
# covered by run-zephyr-fvp-ci.sh. This lane proves: the workspace build
# (nros configure + codegen + host CycloneDDS self-provision) and the runtime —
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
# Corrosion (the CMake road's Rust bridge) comes from the SDK store and a
# configure no longer fetches it (nano-ros RFC-0104 D10). Provisioned from the
# workspace root so actuation_module/nros-sdk.lock governs the version.
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS}/packages/cli/target/release/nros" setup \
      --index "${NROS}/nros-sdk-index.toml" --tool corrosion )

echo "Phase 1 - FreeRTOS POSIX (nano-ros) controller build"
"${ROOT_DIR}/build.sh" --platform freertos-posix -d "${BUILD_ROOT}"

# build.sh ran `nros configure` before the cmake configure; this asserts nothing it writes
# is missing or stale afterwards (nano-ros's CI hook for the same check).
echo "Phase 1b - nros configure --check"
( cd "${ROOT_DIR}/actuation_module" && "${NROS}/packages/cli/target/release/nros" configure --check . )

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
# takes the not-ready path every cycle. The supervisor (vp_si_control_contract)
# then publishes HOLD carrying the stopped payload rather than nothing
# (silence lets a stale command stay latched downstream) -- this marker asserts
# both that the loop runs and that the not-ready path is the one it takes.
require_marker "${log}" "Supervision mode: si"
require_marker "${log}" "Control is skipped since input data is not ready."
# SI_DDS_INTERFACE (upstream #75): with no override Cyclone picks the
# interface itself; the variable overrides it at run time, so one released
# binary serves loopback (CI) and a LAN. The CI container sets no
# CYCLONEDDS_URI, so the default line is the auto one.
require_marker "${log}" "Network interface: auto [default]"
echo "Controller smoke OK: boot markers + control-loop spin observed"

echo "Phase 2b - SI_DDS_INTERFACE runtime override"
for sel in "127.0.0.1|Network interface (by IP address): 127.0.0.1 [SI_DDS_INTERFACE]" \
           "lo|Network interface (by name): lo [SI_DDS_INTERFACE]" \
           "auto|Network interface: auto [SI_DDS_INTERFACE]"; do
  value="${sel%%|*}"
  marker="${sel#*|}"
  env_log="${BUILD_ROOT}/controller-env-${value}.log"
  SI_DDS_INTERFACE="${value}" NROS_ENTRY_SPIN_MS=3000 run_with_timeout "${entry}" "${env_log}" 15
  require_marker "${env_log}" "${marker}"
  require_marker "${env_log}" "Actuation Safety Island is Live"
done
# A name that is no interface reaches Cyclone (presence_required), so the
# session refuses to open: proof the selector is applied, not only logged.
set +e
SI_DDS_INTERFACE=nosuch0 NROS_ENTRY_SPIN_MS=3000 timeout --kill-after=10s 15s "${entry}" \
  >"${BUILD_ROOT}/controller-env-nosuch0.log" 2>&1
set -e
require_marker "${BUILD_ROOT}/controller-env-nosuch0.log" "RMW session open failed"
forbid_marker "${BUILD_ROOT}/controller-env-nosuch0.log" "Actuation Safety Island is Live"
echo "SI_DDS_INTERFACE override OK"

echo "Phase 3 - supervision / policy host unit tests (dependency-free)"
cmake -S "${ROOT_DIR}/actuation_module/test/host" -B "${BUILD_ROOT}-host-tests"
cmake --build "${BUILD_ROOT}-host-tests"
ctest --test-dir "${BUILD_ROOT}-host-tests" --output-on-failure
echo "host unit tests OK"

echo "Phase 5 - Python CAN decoder golden vectors"
python3 "${ROOT_DIR}/demo/can_carla_bridge/test_decoder.py"
python3 "${ROOT_DIR}/demo/can_carla_bridge/test_bridge.py"
echo "CAN bridge checks OK"

echo "Phase 6 - Bridge contract (bridge-config.yaml vs topics.rst, cyclonedds-domain2.xml)"
python3 "${ROOT_DIR}/.github/scripts/check-bridge-contract.py"

echo "Phase 7 - CAN UDP tunnel pack/unpack"
python3 "${ROOT_DIR}/demo/can_tunnel_bridge/test_datagram.py"
echo "CAN UDP datagram tests OK"

echo "FreeRTOS POSIX (nano-ros) runtime validation OK"
