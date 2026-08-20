#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# run-tap-demo.sh — the FVP tap demo, end-to-end, one command.
#
# Brings up the closed loop validated in phase-3 W3:
#   demo compose stack (autoware planning sim + domain bridge + visualizer)
#   + the safety island on FVP_BaseR_AEMv8R over tap0 (DDS domain 2),
#   seeds ego pose + goal headless, and verifies
#   /control/trajectory_follower/control_cmd streams back on domain 1.
#
# Usage:
#   scripts/run-tap-demo.sh            # build (incremental) + up + seed + verify
#   scripts/run-tap-demo.sh --no-seed  # up only; seed by hand / via rviz
#   scripts/run-tap-demo.sh --down     # stop FVP + compose stack
#
# Prereqs (one-time):
#   scripts/bootstrap-asi.sh && source ./activate-asi.sh
#   sudo scripts/setup-tap.sh          # root; this script never sudos
#   ARM FVP under tools/fvp/ or ARMFVP_BIN_PATH set (license-gated download)
#
# The island keeps running after the script exits (log under log/); re-run
# with --down to stop everything. tap0 stays up (setup-tap.sh --delete).
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BUILD_DIR="${ROOT}/build/zephyr-fvp-tap"
LOG_DIR="${ROOT}/log"
FVP_LOG="${LOG_DIR}/tap-demo-fvp.log"
FVP_PID_FILE="${LOG_DIR}/tap-demo-fvp.pid"
AUTOWARE_CTR="demo-safety-island-autoware-1"
BOOT_MARKER="Actuation Safety Island is Live"
BOOT_TIMEOUT_S=120
# W3 runbook seed (sample-map-planning): ego spawn + goal ~30 m along heading.
INITIALPOSE='{header: {frame_id: map}, pose: {pose: {position: {x: 3722.16, y: 73723.1, z: 0.0}, orientation: {z: 0.777, w: 0.629}}}}'
GOALPOSE='{header: {frame_id: map}, pose: {position: {x: 3715.9, y: 73752.5, z: 0.0}, orientation: {z: 0.777, w: 0.629}}}'

say()  { echo -e "\033[0;32m[tap-demo]\033[0m $*"; }
warn() { echo -e "\033[0;33m[tap-demo]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[tap-demo]\033[0m $*" >&2; exit 1; }

in_autoware() {
  docker exec "${AUTOWARE_CTR}" bash -c "source /opt/autoware/setup.bash 2>/dev/null && $*"
}

demo_down() {
  say "stopping FVP…"
  if [[ -f "${FVP_PID_FILE}" ]]; then
    kill "$(cat "${FVP_PID_FILE}")" 2>/dev/null || true
    rm -f "${FVP_PID_FILE}"
  fi
  pkill -f FVP_BaseR_AEMv8R 2>/dev/null || true
  say "stopping compose stack…"
  ( cd "${ROOT}/demo" && docker compose down )
  say "done. tap0 left up (sudo scripts/setup-tap.sh --delete to remove)."
}

DO_SEED=1
case "${1:-}" in
  --down)    demo_down; exit 0 ;;
  --no-seed) DO_SEED=0 ;;
  "")        ;;
  *) die "unknown arg '$1' (usage: run-tap-demo.sh [--no-seed|--down])" ;;
esac

# ---- preflight ----
ip link show tap0 >/dev/null 2>&1 || \
  die "no tap0 — run: sudo scripts/setup-tap.sh   (root; not run for you)"
docker info >/dev/null 2>&1 || die "docker not available."
command -v west >/dev/null 2>&1 || {
  [[ -f "${ROOT}/activate-asi.sh" ]] && source "${ROOT}/activate-asi.sh"
  command -v west >/dev/null 2>&1 || die "west not on PATH — source ./activate-asi.sh first."
}
if [[ -z "${ARMFVP_BIN_PATH:-}" ]]; then
  [[ -x "${ROOT}/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin/FVP_BaseR_AEMv8R" ]] || \
    die "FVP not found — set ARMFVP_BIN_PATH or install under tools/fvp/ (see tools/README.md)."
  export ARMFVP_BIN_PATH="${ROOT}/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin"
fi
mkdir -p "${LOG_DIR}"

# ---- build (incremental; no-op when up to date) ----
# cache_state_modelled=0 is REQUIRED for interactive runs: with the default =1
# the model crawls ~1000x under busy code (W3 runbook). Baked at build time.
say "building tap image (incremental)…"
export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS:-} -C cache_state_modelled=0"
( cd "${ROOT}" && ./build.sh --platform zephyr-fvp --network tap -d "${BUILD_DIR}" ) \
  > "${LOG_DIR}/tap-demo-build.log" 2>&1 || die "build failed — see ${LOG_DIR}/tap-demo-build.log"

# ---- compose stack ----
say "starting demo compose stack…"
( cd "${ROOT}/demo" && docker compose up -d )

# ---- boot the island ----
say "booting the island on FVP (log: ${FVP_LOG})…"
rm -f "${FVP_LOG}"
# Plain background + disown — a `( cmd & echo $! )` subshell here once left
# west as a FOREGROUND child (bash subshell fork optimization: `$!` was the
# script's own pid) and the script sat in wait() forever.
nohup west build -d "${BUILD_DIR}" --target run > "${FVP_LOG}" 2>&1 &
FVP_PID=$!
disown "${FVP_PID}" 2>/dev/null || true
echo "${FVP_PID}" > "${FVP_PID_FILE}"
for ((i = 0; i < BOOT_TIMEOUT_S; i++)); do
  grep -q "${BOOT_MARKER}" "${FVP_LOG}" 2>/dev/null && break
  kill -0 "${FVP_PID}" 2>/dev/null || die "FVP exited early — see ${FVP_LOG}"
  sleep 1
done
grep -q "${BOOT_MARKER}" "${FVP_LOG}" 2>/dev/null || \
  die "no '${BOOT_MARKER}' within ${BOOT_TIMEOUT_S}s — see ${FVP_LOG}"
say "island is live."

# ---- seed ego + goal ----
if ((DO_SEED)); then
  say "waiting for the planning sim, then seeding initialpose + goal…"
  for ((i = 0; i < 60; i++)); do
    in_autoware "ros2 topic list 2>/dev/null | grep -q /initialpose" && break
    sleep 2
  done
  in_autoware "ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped '${INITIALPOSE}'" >/dev/null
  sleep 5
  in_autoware "ros2 topic pub --once /planning/mission_planning/goal geometry_msgs/msg/PoseStamped '${GOALPOSE}'" >/dev/null
fi

# ---- verify the closed loop ----
say "verifying control_cmd on domain 1 (island MPC+PID → bridge)…"
HZ_OUT="$(in_autoware "timeout 25 ros2 topic hz /control/trajectory_follower/control_cmd 2>&1 | tail -4" || true)"
echo "${HZ_OUT}"
if echo "${HZ_OUT}" | grep -q "average rate"; then
  say "CLOSED LOOP OK — healthy is ~19 Hz+ (faster in the emergency-stop state). Island keeps running;"
  say "  stop everything:  scripts/run-tap-demo.sh --down"
  say "  island log:       tail -f ${FVP_LOG}"
else
  die "no control_cmd traffic — island log: ${FVP_LOG}; bridge: docker logs demo-safety-island-bridge-1"
fi
