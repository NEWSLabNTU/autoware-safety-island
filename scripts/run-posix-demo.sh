#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# run-posix-demo.sh — the FreeRTOS POSIX demo, end-to-end, one command.
#
# The host-only sibling of run-tap-demo.sh (no FVP, no tap0, no sudo):
#   demo compose stack (autoware planning sim + domain bridge + visualizer,
#   posix override) + the safety island as the FreeRTOS POSIX simulator
#   process on DDS domain 2 over a multicast-capable host interface,
#   seeds ego pose + goal headless, and verifies
#   /control/trajectory_follower/control_cmd streams back on domain 1.
#
# Usage:
#   scripts/run-posix-demo.sh            # build (incremental) + up + seed + verify
#   scripts/run-posix-demo.sh --no-seed  # up only; seed by hand / via rviz (:6080)
#   scripts/run-posix-demo.sh --down     # stop the island + compose stack
#
# Interface selection: set SAFETY_ISLAND_DDS_INTERFACE to a multicast-capable
# host interface; unset, the default-route interface is used.
#
# Prereqs (one-time): scripts/bootstrap-asi.sh (nros CLI toolchain; build.sh
# self-provisions the rest).
#
# The island keeps running after the script exits (log under log/); re-run
# with --down to stop everything.
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BUILD_DIR="${ROOT}/build/freertos-posix"
ENTRY="${BUILD_DIR}/src/freertos_posix_entry/actuation_posix_entry"
ENTRY_PATTERN="src/freertos_posix_entry/actuation_posix_entry"
LOG_DIR="${ROOT}/log"
ISLAND_LOG="${LOG_DIR}/posix-demo-island.log"
ISLAND_PID_FILE="${LOG_DIR}/posix-demo-island.pid"
AUTOWARE_CTR="demo-safety-island-autoware-1"
BOOT_MARKER="Actuation Safety Island is Live"
BOOT_TIMEOUT_S=60
COMPOSE_FILES=(-f docker-compose.yaml -f docker-compose.posix.yaml)
# W3 runbook seed (sample-map-planning): ego spawn + goal ~30 m along heading.
INITIALPOSE='{header: {frame_id: map}, pose: {pose: {position: {x: 3722.16, y: 73723.1, z: 0.0}, orientation: {z: 0.777, w: 0.629}}}}'
GOALPOSE='{header: {frame_id: map}, pose: {position: {x: 3715.9, y: 73752.5, z: 0.0}, orientation: {z: 0.777, w: 0.629}}}'

say()  { echo -e "\033[0;32m[posix-demo]\033[0m $*"; }
warn() { echo -e "\033[0;33m[posix-demo]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[posix-demo]\033[0m $*" >&2; exit 1; }

in_autoware() {
  docker exec "${AUTOWARE_CTR}" bash -c "source /opt/autoware/setup.bash 2>/dev/null && $*"
}

# nano-ros issue 0746 — stale island processes silently contaminate every rate
# measurement on the shared domain (ros2 topic hz SUMS publishers: a 30 ms
# timer once "measured" 50 Hz because three leftover entries were still
# publishing). Any entry not started by this run is debris; kill it loudly.
kill_stale_islands() {
  local pids
  pids="$(pgrep -f "${ENTRY_PATTERN}" || true)"
  if [[ -n "${pids}" ]]; then
    warn "killing stale island process(es): $(echo "${pids}" | tr '\n' ' ')(issue 0746 — they falsify rate measurements)"
    # shellcheck disable=SC2086
    kill ${pids} 2>/dev/null || true
    sleep 1
    pids="$(pgrep -f "${ENTRY_PATTERN}" || true)"
    if [[ -n "${pids}" ]]; then
      # shellcheck disable=SC2086
      kill -9 ${pids} 2>/dev/null || true
    fi
  fi
  rm -f "${ISLAND_PID_FILE}"
}

demo_down() {
  say "stopping the island…"
  kill_stale_islands
  say "stopping compose stack…"
  ( cd "${ROOT}/demo" && docker compose "${COMPOSE_FILES[@]}" down )
  say "done."
}

DO_SEED=1
case "${1:-}" in
  --down)    demo_down; exit 0 ;;
  --no-seed) DO_SEED=0 ;;
  "")        ;;
  *) die "unknown arg '$1' (usage: run-posix-demo.sh [--no-seed|--down])" ;;
esac

# ---- preflight ----
docker info >/dev/null 2>&1 || die "docker not available."
if [[ -z "${SAFETY_ISLAND_DDS_INTERFACE:-}" ]]; then
  SAFETY_ISLAND_DDS_INTERFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "${SAFETY_ISLAND_DDS_INTERFACE}" ]] || \
    die "no default-route interface — set SAFETY_ISLAND_DDS_INTERFACE to a multicast-capable interface."
  say "SAFETY_ISLAND_DDS_INTERFACE not set — using default-route interface '${SAFETY_ISLAND_DDS_INTERFACE}'."
fi
export SAFETY_ISLAND_DDS_INTERFACE
ip link show "${SAFETY_ISLAND_DDS_INTERFACE}" >/dev/null 2>&1 || \
  die "interface '${SAFETY_ISLAND_DDS_INTERFACE}' does not exist."
mkdir -p "${LOG_DIR}"

# ---- build (incremental; no-op when up to date) ----
say "building the freertos-posix island (incremental)…"
( cd "${ROOT}" && ./build.sh --platform freertos-posix -d "${BUILD_DIR}" ) \
  > "${LOG_DIR}/posix-demo-build.log" 2>&1 || die "build failed — see ${LOG_DIR}/posix-demo-build.log"
[[ -x "${ENTRY}" ]] || die "entry missing after build: ${ENTRY}"

# ---- compose stack ----
say "starting demo compose stack (posix override, iface ${SAFETY_ISLAND_DDS_INTERFACE})…"
( cd "${ROOT}/demo" && docker compose "${COMPOSE_FILES[@]}" up -d )

# ---- boot the island ----
kill_stale_islands
say "booting the island (log: ${ISLAND_LOG})…"
rm -f "${ISLAND_LOG}"
# Hosted env-rung resolution (#206): domain 2 + the posix cyclonedds profile,
# no rebuild needed. Plain background + disown — see run-tap-demo.sh for why
# not a `( cmd & echo $! )` subshell.
nohup env ROS_DOMAIN_ID=2 \
  CYCLONEDDS_URI="file://${ROOT}/demo/cyclonedds.posix.xml" \
  SAFETY_ISLAND_DDS_INTERFACE="${SAFETY_ISLAND_DDS_INTERFACE}" \
  "${ENTRY}" > "${ISLAND_LOG}" 2>&1 &
ISLAND_PID=$!
disown "${ISLAND_PID}" 2>/dev/null || true
echo "${ISLAND_PID}" > "${ISLAND_PID_FILE}"
for ((i = 0; i < BOOT_TIMEOUT_S; i++)); do
  grep -aq "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null && break
  kill -0 "${ISLAND_PID}" 2>/dev/null || die "island exited early — see ${ISLAND_LOG}"
  sleep 1
done
grep -aq "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null || \
  die "no '${BOOT_MARKER}' within ${BOOT_TIMEOUT_S}s — see ${ISLAND_LOG}"
say "island is live (pid ${ISLAND_PID})."

# ---- seed ego + goal ----
# Seeding is FEEDBACK-DRIVEN: a pose published before the sim can consume it is
# silently lost (/initialpose EXISTING is not readiness — a cold container takes
# minutes to boot the planner, and the first run of this script seeded into the
# void). Pose is accepted when /localization/kinematic_state starts publishing;
# the goal when the planner emits a trajectory. Retry each until its effect.
seed_ego_and_goal() {
  say "waiting for the planning sim, then seeding initialpose + goal…"
  for ((i = 0; i < 60; i++)); do
    in_autoware "ros2 topic list 2>/dev/null | grep -q /initialpose" && break
    sleep 2
  done
  local ok=0
  for ((i = 0; i < 10; i++)); do
    in_autoware "ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped '${INITIALPOSE}'" >/dev/null
    if in_autoware "timeout 8 ros2 topic echo --once /localization/kinematic_state >/dev/null 2>&1"; then
      ok=1; break
    fi
    warn "initialpose not accepted yet (attempt $((i + 1))/10) — sim still booting; retrying…"
  done
  ((ok)) || die "initialpose never accepted — check: docker logs ${AUTOWARE_CTR}"
  ok=0
  for ((i = 0; i < 10; i++)); do
    in_autoware "ros2 topic pub --once /planning/mission_planning/goal geometry_msgs/msg/PoseStamped '${GOALPOSE}'" >/dev/null
    if in_autoware "timeout 8 ros2 topic echo --once /planning/scenario_planning/trajectory >/dev/null 2>&1"; then
      ok=1; break
    fi
    warn "no trajectory yet (attempt $((i + 1))/10) — retrying goal…"
  done
  ((ok)) || die "goal produced no trajectory — check: docker logs ${AUTOWARE_CTR}"
  say "ego + goal seeded (trajectory streaming)."
}
if ((DO_SEED)); then
  seed_ego_and_goal
fi

# ---- verify the closed loop ----
# Guard the measurement (issue 0746): exactly ONE island may be publishing.
N_ISLANDS="$(pgrep -fc "${ENTRY_PATTERN}" || true)"
[[ "${N_ISLANDS}" == "1" ]] || \
  die "expected exactly 1 island process, found ${N_ISLANDS} — a stale entry would falsify the rate."
say "verifying control_cmd on domain 1 (island MPC+PID → bridge)…"
HZ_OUT="$(in_autoware "timeout 25 ros2 topic hz /control/trajectory_follower/control_cmd 2>&1 | tail -4" || true)"
echo "${HZ_OUT}"
if echo "${HZ_OUT}" | grep -q "average rate"; then
  say "CLOSED LOOP OK — healthy is ~31.7 Hz (30 ms control tier + posix-sim tick skew). Island keeps running;"
  say "  stop everything:  scripts/run-posix-demo.sh --down"
  say "  island log:       tail -f ${ISLAND_LOG}"
  say "  visualizer:       http://localhost:6080"
else
  die "no control_cmd traffic — island log: ${ISLAND_LOG}; bridge: docker logs demo-safety-island-bridge-1"
fi
