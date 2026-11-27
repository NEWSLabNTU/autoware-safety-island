#!/usr/bin/env bash
# Zephyr FVP TAP UDP tunnel: the CAN output test program on the tap network,
# its frames tunnelled over UDP to the host gateway and onto vcan0
# (actuation_module/test/run-fvp-tap-tunnel.sh).
#
# The build runs here; the test runs in a network namespace of its own with
# tap0 and vcan0 made inside it (scripts/run-in-netns.sh): a docker container
# with NET_ADMIN and /dev/net/tun on a dev box, the job container itself on
# CI (ASI_NETNS_DIRECT=1; the workflow gives it the same two). No sudo, no
# password, and no host interface is created or changed.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_ROOT="${ROOT_DIR}/build/zephyr-fvp-tap-can"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"
# build.sh generates the message bindings from AMENT_PREFIX_PATH, as the
# validation step does (run-zephyr-fvp-ci.sh).
source_ament_env

ensure_zephyr_workspace()
{
  pip3 install -q -r "${ROOT_DIR}/zephyr/scripts/requirements-base.txt"
  pip3 install -q -r "${ROOT_DIR}/zephyr/scripts/requirements-build-test.txt"
  (
    cd "${ROOT_DIR}"
    if [ ! -d .west ]; then
      .github/scripts/ensure-nros-checkout.sh
      west init -l actuation_module
      west update
    fi
    west zephyr-export
  )
}

mkdir -p "${ROOT_DIR}/build"
ensure_zephyr_workspace
# nano-ros's Zephyr 3.7 patch set, as run-zephyr-fvp-ci.sh applies it
# (idempotent): a Rust image refuses to configure without it.
bash "${ROOT_DIR}/modules/nros/scripts/zephyr/patches/3.7.sh" "${ROOT_DIR}"
ensure_fvp_available

echo "Zephyr FVP TAP UDP tunnel build"
"${ROOT_DIR}/build.sh" --platform zephyr-fvp --network tap --can-output-test \
  -d "${BUILD_ROOT}"

echo "Zephyr FVP TAP UDP tunnel run (tap0 + vcan0 in a network namespace of their own)"
# The model console and the gateway log go beside the FVP lane's logs (the
# zephyr-fvp-logs artifact).
export FVP_TAP_LOG_DIR="${FVP_TAP_LOG_DIR:-${ROOT_DIR}/build/zephyr-fvp/logs}"
"${ROOT_DIR}/scripts/run-in-netns.sh" --vcan --tap -- \
  "${ROOT_DIR}/actuation_module/test/run-fvp-tap-tunnel.sh" "${BUILD_ROOT}"
echo "FVP TAP tunnel OK"

# nano-ros 0758 part 2 (phase-15 P5): the fvp-tap controller image re-syncs
# its SNTP epoch (clock.sntp_resync_interval_ms > 0) while
# scripts/sntp-server.py steps its time, and the stamps of the island's own
# control_cmd follow the step (actuation_module/test/run-fvp-tap-resync.sh).
echo "Zephyr FVP TAP controller build (SNTP re-sync)"
"${ROOT_DIR}/build.sh" --platform zephyr-fvp --network tap \
  -d "${ROOT_DIR}/build/zephyr-fvp-tap"
echo "Zephyr FVP TAP SNTP re-sync run (tap0 in a network namespace of its own)"
RESYNC_LOG_DIR="${FVP_TAP_LOG_DIR}" "${ROOT_DIR}/scripts/run-in-netns.sh" --tap \
  --env RESYNC_LOG_DIR -- \
  "${ROOT_DIR}/actuation_module/test/run-fvp-tap-resync.sh" "${ROOT_DIR}/build/zephyr-fvp-tap"
echo "FVP TAP SNTP re-sync OK"
