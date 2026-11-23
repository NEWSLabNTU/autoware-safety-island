#!/usr/bin/env bash
# FreeRTOS AN536 runtime CI — the EMULATED Cortex-R52 lane (phase-6 A6).
#
# This is the lane that gives the ARMv8-R code path runtime coverage without
# hardware. The S32Z2 lane compiles the same controller for the same CPU but
# can only be LINKED here: no emulator models the S32Z270 RTU, so until a board
# exists nothing proves that code ever ran. QEMU's mps3-an536 is a dual
# Cortex-R52 with a LAN9118, and nano-ros phase-385's board bundle boots on it —
# so the same image shape that will one day be flashed to silicon is executed on
# every CI run.
#
# Every run is `nros run <image> --expect <line>... --timeout N`; nothing here
# starts QEMU or greps its output by hand.
#
# What it proves: the R52 image boots (EL2->EL1, GICv3, generic-timer tick),
# lwIP comes up over the emulated NIC, the nros entry constructs the controller
# with its launch-seeded parameters and real-time tier, and the control loop
# spins. What it does NOT prove: NETC, the S32 Config Tools PBcfg, the licensed
# GCC/ARM_CR52_GIC port, the S32Z270 memory map, or real-time timing — those
# stay bench-gated (ASI phase-4 W5.b item 5).

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
NROS="${ROOT_DIR}/modules/nros"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

cd "${ROOT_DIR}"

echo "Phase 0 - nano-ros provisioning (CLI, launch-resolve, runners, FreeRTOS kernel, SDK tools)"
nros_cli_select
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" setup "${NROS_SETUP_INDEX_ARGS[@]}" --source freertos-kernel )

# Corrosion is needed by every CMake-road lane (see run-freertos-posix-ci.sh).
#
# Two tools this lane needs that a stock runner does not have, both from the
# nano-ros SDK store so CI matches what a developer gets locally:
#
#   * QEMU >= 9.0 — mps3-an536 does not exist before it, and Ubuntu 22.04 ships
#     6.2. The store's build is 11.0.0.
#   * arm-none-eabi-gcc 13.2 — the system 10.3 REJECTS the entry codegen's C++
#     designated initializers, which fails deep in the build with an error that
#     reads as a codegen bug rather than a toolchain-age one (the same trap
#     build.sh's SDK-first PATH order exists to avoid).
# One tool per call keeps the failure message naming the tool that failed
# (`--tool` is repeatable since nano-ros phase-447, but one plan hides which).
#
# Run from actuation_module/ so the committed nros-sdk.lock there governs the
# versions (the lock is the project's record; `nros update` moves it).
for tool in qemu arm-none-eabi-gcc corrosion; do
  ( cd "${ROOT_DIR}/actuation_module" && \
      "${NROS_CLI}" setup "${NROS_SETUP_INDEX_ARGS[@]}" --tool "${tool}" ) || {
    echo "SDK provisioning failed for ${tool} — see the nros setup output above." >&2
    exit 1
  }
done

# The image's build environment: message sources from the ROS / Autoware
# install (AMENT_PREFIX_PATH), and the nano-ros checkout the CMake road reads.
source_ament_env
export CMAKE_PREFIX_PATH=""
export NROS_REPO_DIR="${NROS}"
if [ "${NROS_CLI_MODE}" = "release" ]; then
  # The release CLI takes the board's sources (FreeRTOS kernel, lwIP, Cyclone
  # DDS) from the SDK store, as the nano-ros book provisions a board.
  ( cd "${ROOT_DIR}/actuation_module" && \
      "${NROS_CLI}" setup mps3-an536-freertos --rmw cyclonedds )
fi

echo "Phase 1 - AN536 (emulated Cortex-R52) controller build"
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" build controller_bringup:an536 )

# nros build ran `nros configure` before the cmake configure; this asserts
# nothing it writes is missing or stale afterwards (nano-ros's CI hook for the
# same check).
echo "Phase 1b - nros configure --check"
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" configure --check . )

# `nros run` boots the image on the board's runner (QEMU mps3-an536 from the
# SDK store, semihosting console, lwIP over the LAN9118) and passes once every
# --expect line has appeared:
#   - Network ready: lwIP is up, which also proves the scheduler and tick run
#     (the netif bring-up waits on FreeRTOS delays);
#   - the boot markers and "is Live";
#   - DDS_ONLY: the bringup's seeded control_output reached the node
#     (launch-parameter seeding end to end, on the cross target);
#   - the [tasks.control] real-time model reached the board's scheduler;
#   - no Autoware upstream here, so the loop takes the not-ready path every
#     cycle, and the supervisor (vp_si_control_contract) publishes HOLD there;
#   - the stamp clock line of the first control cycle. The image's
#     [knobs.clock] source is `board`, the island's SNTP task asking the
#     image's gateway on port 12123; QEMU's user network forwards the gateway
#     (10.0.2.2) to this host's loopback, so the demo responder serves it
#     here. nano-ros resolves the source after the network is up, so the
#     verdict line says `board`, the first cycle stamps absolute, and the
#     sync line names source 3 (board).
echo "Phase 2 - runtime smoke on QEMU (nros run)"
python3 "${ROOT_DIR}/scripts/sntp-server.py" --bind 127.0.0.1 --port 12123 &
SNTP_PID=$!
trap 'kill "${SNTP_PID}" 2>/dev/null || true' EXIT
( cd "${ROOT_DIR}/actuation_module" && "${NROS_CLI}" run controller_bringup:an536 --timeout 90 \
    --expect "Network ready" \
    --expect "nros: wall clock from board" \
    --expect "Stamp clock:" \
    --expect "Stamp clock: absolute" \
    --expect "nano-ros wall clock synced, source 3" \
    --expect "Starting Controller Node" \
    --expect "Controller Node Started" \
    --expect "Actuation Safety Island is Live" \
    --expect "Control command output mode: DDS_ONLY" \
    --expect "sched task priority set sched_task=\`control\`" \
    --expect "Supervision mode: si" \
    --expect "Control is skipped since input data is not ready." )
kill "${SNTP_PID}" 2>/dev/null || true
echo "AN536 smoke OK: R52 boot + lwIP + controller markers + control-loop spin"

# The test programs (actuation_module/test), each an image of its own
# (src/test_bringup), on the same board. Their entry is the program's own
# package; nros run takes its executable from the build (nano-ros issue 2752).
echo "Phase 3 - unit test on QEMU (nros run)"
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" build unit_test_bringup:mps3-an536-freertos && \
    "${NROS_CLI}" run unit_test_bringup:mps3-an536-freertos --timeout 120 \
      --expect "=== All Tests Passed ===" )

echo "Phase 4 - DDS loopback test on QEMU (nros run)"
( cd "${ROOT_DIR}/actuation_module" && \
    "${NROS_CLI}" build dds_loopback_test_bringup:mps3-an536-freertos && \
    "${NROS_CLI}" run dds_loopback_test_bringup:mps3-an536-freertos --timeout 120 \
      --expect "Starting DDS loopback test" \
      --expect "STEERING REPORT" \
      --expect "DDS loopback test passed" )

echo "FreeRTOS AN536 (emulated Cortex-R52) runtime validation OK"
