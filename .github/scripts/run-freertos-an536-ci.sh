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
# What it proves: the R52 image boots (EL2->EL1, GICv3, generic-timer tick),
# lwIP comes up over the emulated NIC, the nros entry constructs the controller
# with its launch-seeded parameters and real-time tier, and the control loop
# spins. What it does NOT prove: NETC, the S32 Config Tools PBcfg, the licensed
# GCC/ARM_CR52_GIC port, the S32Z270 memory map, or real-time timing — those
# stay bench-gated (ASI phase-4 W5.b item 5).

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_ROOT="${ROOT_DIR}/build/freertos-an536"
NROS="${ROOT_DIR}/modules/nros"
NROS_CLI="${NROS}/packages/cli/target/release/nros"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

cd "${ROOT_DIR}"

echo "Phase 0 - nano-ros provisioning (CLI, launch-resolve, FreeRTOS kernel, SDK tools)"
cargo build --release --manifest-path "${NROS}/packages/cli/Cargo.toml" -p nros-cli
cargo build --release \
  --manifest-path "${NROS}/packages/cli/nros-launch-resolve/Cargo.toml"
ln -sf "${NROS}/packages/cli/nros-launch-resolve/target/release/nros-launch-resolve" \
       "${NROS}/packages/cli/target/release/nros-launch-resolve"
( cd "${NROS}" && "${NROS_CLI}" setup --source freertos-kernel )

# Two tools this lane needs that a stock runner does not have, both from the
# nano-ros SDK store so CI matches what a developer gets locally:
#
#   * QEMU >= 9.0 — mps3-an536 does not exist before it, and Ubuntu 22.04 ships
#     6.2. The store's build is 11.0.0.
#   * arm-none-eabi-gcc 13.2 — the system 10.3 REJECTS the entry codegen's C++
#     designated initializers, which fails deep in the build with an error that
#     reads as a codegen bug rather than a toolchain-age one (the same trap
#     build.sh's SDK-first PATH order exists to avoid).
# `--tool` takes ONE name (it is not repeatable — passing two prints the usage
# and exits 0, which would look like success and leave the tool missing).
for tool in qemu arm-none-eabi-gcc; do
  ( cd "${NROS}" && "${NROS_CLI}" setup --tool "${tool}" ) || {
    echo "SDK provisioning failed for ${tool} — see the nros setup output above." >&2
    exit 1
  }
done

# Resolve the store's QEMU explicitly (newest first, mirroring activate.sh and
# build.sh) rather than trusting PATH, which may still hold the system one.
sdk_qemu_bin=$(find "${NROS_HOME:-$HOME/.nros}/sdk/qemu" \
    -maxdepth 2 -type d -name bin 2>/dev/null | sort -Vr | head -1)
QEMU="${QEMU_SYSTEM_ARM:-}"
if [ -z "${QEMU}" ] && [ -n "${sdk_qemu_bin}" ] && [ -x "${sdk_qemu_bin}/qemu-system-arm" ]; then
  QEMU="${sdk_qemu_bin}/qemu-system-arm"
fi
QEMU="${QEMU:-qemu-system-arm}"

if ! command -v "${QEMU}" >/dev/null 2>&1 && [ ! -x "${QEMU}" ]; then
  echo "${QEMU} not found — the SDK store has no qemu and PATH has none." >&2
  exit 1
fi
# The machine arrived in QEMU 9.0; an older binary reports "unsupported machine
# type", which is worth naming rather than letting the boot look dead.
if ! "${QEMU}" -machine help 2>/dev/null | grep -q "mps3-an536"; then
  echo "${QEMU} has no mps3-an536 machine (needs QEMU >= 9.0):" >&2
  "${QEMU}" --version >&2 || true
  exit 1
fi
echo "QEMU: ${QEMU} ($("${QEMU}" --version | head -1))"

echo "Phase 1 - AN536 (emulated Cortex-R52) controller build"
"${ROOT_DIR}/build.sh" --platform freertos-an536 -d "${BUILD_ROOT}"

echo "Phase 2 - runtime smoke on QEMU"
entry="${BUILD_ROOT}/src/freertos_an536_entry/actuation_an536_entry"
test -x "${entry}"
log="${BUILD_ROOT}/controller.log"
rm -f "${log}"
set +e
# The image never exits on its own (the scheduler owns it), so the timeout IS
# the run length; a timeout kill is the expected outcome, not a failure.
timeout --kill-after=10s 90s \
  "${QEMU}" -machine mps3-an536 -nographic \
            -semihosting-config enable=on,target=native \
            -kernel "${entry}" >"${log}" 2>&1
rc=$?
set -e
if ! is_success_or_timeout "${rc}"; then
  dump_log "${log}"
  echo "QEMU exited unexpectedly: ${rc}" >&2
  exit "${rc}"
fi

# lwIP over the emulated LAN9118 — also the proof that the scheduler and tick
# are alive, since the netif bring-up waits on FreeRTOS delays.
require_marker "${log}" "Network ready"
require_marker "${log}" "Starting Controller Node"
require_marker "${log}" "Controller Node Started"
require_marker "${log}" "Actuation Safety Island is Live"
# The bringup's seeded control_output drives the node — launch-param seeding
# end to end, on the cross target.
require_marker "${log}" "Control command output mode: DDS_ONLY"
# The [tiers.control] real-time model reached the board's scheduler.
require_marker "${log}" "tier priority set tier=\`control\`"
# No Autoware upstream here, so the loop takes the not-ready path every cycle
# and must SAY so by commanding a stop (the 2026-08-24 safety hardening).
require_marker "${log}" "Inputs not ready — commanding safe stop"
echo "AN536 smoke OK: R52 boot + lwIP + controller markers + control-loop spin"

echo "FreeRTOS AN536 (emulated Cortex-R52) runtime validation OK"
