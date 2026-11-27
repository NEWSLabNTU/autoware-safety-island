#!/usr/bin/env bash
# FreeRTOS POSIX runtime CI phases — nano-ros workspace lane (phase-4 W5.a).
#
# This lane proves: the workspace build (nros configure + codegen + host
# CycloneDDS self-provision) and the runtime -- board-owned FreeRTOS
# scheduler, controller task boot markers, CAN mock, control-loop spin -- and
# runs the unit and DDS loopback test programs. Every run is `nros run <image>
# --expect <line>... --timeout N`.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
NROS="${ROOT_DIR}/modules/nros"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

cd "${ROOT_DIR}"

echo "Phase 0 - nano-ros provisioning (CLI, launch-resolve, runners, FreeRTOS kernel)"
nros_cli_select
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" setup "${NROS_SETUP_INDEX_ARGS[@]}" --source freertos-kernel )
# Corrosion (the CMake road's Rust bridge) comes from the SDK store and a
# configure no longer fetches it (nano-ros RFC-0104 D10). Provisioned from the
# workspace root so actuation_module/nros-sdk.lock governs the version.
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" setup "${NROS_SETUP_INDEX_ARGS[@]}" --tool corrosion )

# The image's build environment: message sources from the ROS / Autoware
# install (AMENT_PREFIX_PATH), and the nano-ros checkout the CMake road reads.
source_ament_env
export CMAKE_PREFIX_PATH=""
export NROS_REPO_DIR="${NROS}"

echo "Phase 1 - FreeRTOS POSIX (nano-ros) controller build"
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" build controller_bringup:freertos-posix )

# nros build ran `nros configure` before the cmake configure; this asserts nothing it writes
# is missing or stale afterwards (nano-ros's CI hook for the same check).
echo "Phase 1b - nros configure --check"
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" configure --check . )

# nano-ros's layout checks: the bringup is pure declarative, every
# [[component]] row names <pkg>::<Class> and no system.toml sits beside a
# component, and the workspace's own Zephyr board package resolves (descriptor,
# package.xml announcement, network, nano_ros_use_board() projection). None of
# them builds anything.
echo "Phase 1c - nros check: bringup, workspace layout, S32Z270 Zephyr board package"
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" check --bringup src/controller_bringup && \
    "${NROS_CLI}" check --workspace && \
    "${NROS_CLI}" check s32z270-rtu0-zephyr )

# Every parameter the controller declares must be seeded by
# controller_bringup/config/*.param.yaml or the launch file, with a value of
# its declared type. (nano-ros sizes each image's parameter store from the
# declarations.)
echo "Phase 1d - parameter seeds"
# The image's resolved plan: the census metadata and the launch record, in
# the configuration-hashed, per-image build directory `nros build` used
# (nano-ros issue 2702: <...>-<bringup>-<image>/cmake).
plan_dir="$(ls -td "${ROOT_DIR}"/actuation_module/build/freertos-cyclonedds-freertos-posix-cfg*-controller_bringup-freertos-posix/cmake/nros-plan | head -1)"
python3 "${ROOT_DIR}/.github/scripts/check-param-seeds.py" "${plan_dir}" \
  "${ROOT_DIR}/actuation_module/src/controller_bringup"

# CycloneDDS on this lane links whatever the image supplies -- in the Autoware
# devcontainer that includes iceoryx -- and the LINKER finding a library says
# nothing about the LOADER finding it. CI died here with
#   error while loading shared libraries: libiceoryx_binding_c.so
# after a clean build and link. Put the prefixes' lib dirs on the run-time path.
#
# Shared with the Zephyr lane, which needs the same directories for a different
# reason -- see add_ros_lib_paths in ci-helpers.sh.
add_ros_lib_paths

# `nros run` starts the image as a host process and passes once every --expect
# line has appeared on its console:
#   - the boot markers and "is Live";
#   - DDS_ONLY: the bringup's seeded control_output drives the node
#     (launch-parameter seeding end to end; the CAN path is the Zephyr lane's
#     can-output-test);
#   - the control loop spins with no upstream Autoware to feed it, so it takes
#     the not-ready path every cycle, and the supervisor
#     (vp_si_control_contract) publishes HOLD with the stopped payload there
#     rather than nothing (silence lets a stale command stay latched);
echo "Phase 2 - runtime smoke (nros run)"
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" run controller_bringup:freertos-posix --timeout 60 \
    --expect "Starting Controller Node" \
    --expect "Controller Node Started" \
    --expect "Actuation Safety Island is Live" \
    --expect "Control command output mode: DDS_ONLY" \
    --expect "Supervision mode: si" \
    --expect "Control is skipped since input data is not ready." )
echo "Controller smoke OK: boot markers + control-loop spin observed"

# The DDS interface is Cyclone's own CYCLONEDDS_URI, which nano-ros's hosted
# Cyclone reads when it opens the session, so one released binary serves
# loopback (CI) and a LAN. By address and by name:
echo "Phase 2b - CYCLONEDDS_URI interface selection"
for sel in 'address="127.0.0.1"' 'name="lo"'; do
  ( cd "${ROOT_DIR}/actuation_module" && \
      CYCLONEDDS_URI="<General><Interfaces><NetworkInterface ${sel} presence_required=\"true\"/></Interfaces></General>" \
      "${NROS_CLI}" run controller_bringup:freertos-posix --timeout 30 \
        --expect "Actuation Safety Island is Live" )
done
# A name that is no interface (presence_required) makes the session refuse to
# open: proof the URI is applied, not only accepted. The run passes on the
# refusal, and fails if its console reaches "is Live" first (--forbid).
( cd "${ROOT_DIR}/actuation_module" && \
    CYCLONEDDS_URI='<General><Interfaces><NetworkInterface name="nosuch0" presence_required="true"/></Interfaces></General>' \
    "${NROS_CLI}" run controller_bringup:freertos-posix --timeout 30 \
      --expect "RMW session open failed" \
      --forbid "Actuation Safety Island is Live" )
echo "CYCLONEDDS_URI interface selection OK"

# The test programs (actuation_module/test), each an image of its own
# (src/test_bringup), on the same board. Their entry is the program's own
# package; nros run takes its executable from the build (nano-ros issue 2752).
echo "Phase 2c - unit test (nros run)"
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" build unit_test_bringup:freertos-posix && \
    "${NROS_CLI}" run unit_test_bringup:freertos-posix --timeout 60 \
      --expect "=== All Tests Passed ===" )

echo "Phase 2d - DDS loopback test (nros run)"
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" build dds_loopback_test_bringup:freertos-posix && \
    "${NROS_CLI}" run dds_loopback_test_bringup:freertos-posix --timeout 60 \
      --expect "Starting DDS loopback test" \
      --expect "STEERING REPORT" \
      --expect "DDS loopback test passed" )

echo "Phase 3 - supervision / policy host unit tests (dependency-free)"
cmake -S "${ROOT_DIR}/actuation_module/test/host" -B "${ROOT_DIR}/build/freertos-posix-host-tests"
cmake --build "${ROOT_DIR}/build/freertos-posix-host-tests"
ctest --test-dir "${ROOT_DIR}/build/freertos-posix-host-tests" --output-on-failure
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
