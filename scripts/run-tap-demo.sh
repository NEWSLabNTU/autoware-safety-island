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
#   scripts/run-tap-demo.sh --drive    # build + up + AUTONOMOUS DRIVING mission
#   scripts/run-tap-demo.sh --no-seed  # up only; seed by hand / via rviz
#   scripts/run-tap-demo.sh --down     # stop the island + compose stack
#
#   --an536  runs the EMULATED Cortex-R52 lane instead of the FVP: the same
#            controller image built for QEMU mps3-an536, on tap1, DDS domain 2.
#            Needs no FVP licence and no west. Combine with --drive/--down.
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
LOG_DIR="${ROOT}/log"
# Lane: "fvp" (Zephyr on ARM FVP, tap0) or "an536" (FreeRTOS on QEMU
# mps3-an536, tap1). Set by --an536; every per-lane value is resolved in
# select_lane() below, and nothing after the island boots depends on it.
LANE="fvp"
BUILD_DIR=""
ISLAND_LOG=""
ISLAND_PID_FILE=""
# The SNTP responder is lane-independent, so its pid file is too.
SNTP_PID_FILE="${LOG_DIR}/tap-demo-sntp.pid"
TAP_IF=""
TAP_HOST_IP=""
SNTP_PORT=""
COMPOSE_FILES=()

select_lane() {
  if [[ "${LANE}" == "an536" ]]; then
    BUILD_DIR="${ROOT}/build/freertos-an536"
    ISLAND_LOG="${LOG_DIR}/tap-demo-an536.log"
    ISLAND_PID_FILE="${LOG_DIR}/tap-demo-an536.pid"
    TAP_IF="tap1"
    # Must match ASI_SNTP_SERVER_IP/PORT baked into the image
    # (src/platform/freertos/wall_clock.cpp) — the image's gateway.
    TAP_HOST_IP="192.0.3.1"
    SNTP_PORT="12123"
    # docker-compose.posix.yaml is misnamed for this use — what it actually
    # does is parameterise which interface DDS domain 2 is pinned to
    # (SAFETY_ISLAND_DDS_INTERFACE), which is exactly what a non-tap0 island
    # needs. The default file hardcodes tap0.
    COMPOSE_FILES=(-f docker-compose.yaml -f docker-compose.posix.yaml)
    export SAFETY_ISLAND_DDS_INTERFACE="${TAP_IF}"
  else
    BUILD_DIR="${ROOT}/build/zephyr-fvp-tap"
    ISLAND_LOG="${LOG_DIR}/tap-demo-fvp.log"
    ISLAND_PID_FILE="${LOG_DIR}/tap-demo-fvp.pid"
    TAP_IF="tap0"
    # Must match CONFIG_SNTP_SERVER_ADDRESS in
    # boards/fvp_baser_aemv8r_..._tap_network.conf — without an epoch the
    # island stamps from 1970 and vehicle_cmd_gate rejects the commands as
    # stale, so autonomous mode never actuates.
    TAP_HOST_IP="192.168.10.1"
    SNTP_PORT="12123"
    COMPOSE_FILES=(-f docker-compose.yaml)
  fi
}
AUTOWARE_CTR="demo-safety-island-autoware-1"
BOOT_MARKER="Actuation Safety Island is Live"
# 200 s, matching .github/scripts/run-zephyr-fvp-ci.sh. The CI timeout was
# raised from 90 s in 3ad3cdb because "the boot grew with the pin" and a slow
# boot failed as a MISSING MARKER, which reads as a broken image rather than a
# slow one. This script had the same failure mode at 120 s.
BOOT_TIMEOUT_S=200
# W3 runbook seed (sample-map-planning): ego spawn + goal ~30 m along heading.
# NOTE (2026-08-24): this pair verifies the E-STOP closed loop only — the
# goal snaps to a crossing lane, the planner emits a goal-anchored
# zero-velocity sliver, and the island correctly refuses to track it. For a
# DRIVING run, seed a lane-consistent pair and route via ADAPI (bare goal
# publishes leave route_state UNSET, which blocks autonomous):
#   /initialpose  x 3714.44 y 73753.15  ori z 0.25 w 0.968   (on-lane, lane heading)
#   ros2 service call /api/routing/set_route_points ... goal x 3730.2 y 73761.8
#   ros2 service call /api/operation_mode/change_to_autonomous ...
# Expect a HOST-side runaway after arrival: when the planner stops publishing
# on goal arrival, Autoware's trajectory rate check errors, MRM engages, and
# this image's mrm_emergency_stop_operator ramps the WRONG way (its command
# diverges; vehicle_cmd_gate clamps it to 25 m/s / +4 m/s² and the sim runs
# away). The island keeps commanding a safe stop throughout — see the
# phase-4 driving re-baseline note. Re-seed the pose or change_to_stop to
# recover.
INITIALPOSE='{header: {frame_id: map}, pose: {pose: {position: {x: 3722.16, y: 73723.1, z: 0.0}, orientation: {z: 0.777, w: 0.629}}}}'
GOALPOSE='{header: {frame_id: map}, pose: {position: {x: 3715.9, y: 73752.5, z: 0.0}, orientation: {z: 0.777, w: 0.629}}}'

say()  { echo -e "\033[0;32m[tap-demo]\033[0m $*"; }
warn() { echo -e "\033[0;33m[tap-demo]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[tap-demo]\033[0m $*" >&2; exit 1; }

in_autoware() {
  docker exec "${AUTOWARE_CTR}" bash -c "source /opt/autoware/setup.bash 2>/dev/null && $*"
}

demo_down() {
  say "stopping the island…"
  if [[ -f "${ISLAND_PID_FILE}" ]]; then
    kill "$(cat "${ISLAND_PID_FILE}")" 2>/dev/null || true
    rm -f "${ISLAND_PID_FILE}"
  fi
  if [[ "${LANE}" == "an536" ]]; then
    # A leftover QEMU keeps the tap open, and the NEXT run then exits with
    # "could not configure /dev/net/tun: Device or resource busy" while the
    # surrounding script keeps going — a clean-looking failure with no island.
    pkill -f "qemu-system-arm -machine mps3-an536" 2>/dev/null || true
    pkill -f "sntp-server.py --bind ${TAP_HOST_IP}" 2>/dev/null || true
  else
    # Sweep any model still holding THIS repo's ELFs, selected on the build
    # path AND the ELF name.
    #
    # `pkill -f FVP_BaseR_AEMv8R` was here and is a footgun: `-f` matches whole
    # command lines, so any shell whose own command line mentions that string --
    # including the one running this script -- is a candidate. It killed the
    # calling shell three separate times during phase-7 work.
    #
    # Both conditions are load-bearing. Matching the path alone would also
    # select build.sh, west and cmake; killing those mid-run is worse than the
    # orphan being swept.
    local stray
    stray="$(ps -eo pid,args 2>/dev/null \
             | grep -F "${ROOT}/build/" \
             | grep -F 'zephyr.elf' \
             | grep -v ' grep ' \
             | awk '{print $1}')"
    if [[ -n "${stray}" ]]; then
      warn "sweeping stray FVP pids: $(echo "${stray}" | tr '\n' ' ')"
      # shellcheck disable=SC2086
      kill -KILL ${stray} 2>/dev/null || true
    fi
  fi
  # Pid-file shutdown for the responder, kept from the FVP lane: pkill by
  # pattern only finds it while the pattern still matches, and the pid file
  # survives a rename of the bind address.
  if [[ -f "${SNTP_PID_FILE}" ]]; then
    say "stopping SNTP responder…"
    kill "$(cat "${SNTP_PID_FILE}")" 2>/dev/null || true
    rm -f "${SNTP_PID_FILE}"
  fi
  say "stopping compose stack…"
  ( cd "${ROOT}/demo" && docker compose "${COMPOSE_FILES[@]}" down )
  say "done. ${TAP_IF} left up (sudo scripts/setup-tap.sh --delete to remove)."
}

DO_SEED=1
DO_DRIVE=0
DO_DOWN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --an536)   LANE="an536" ;;
    --down)    DO_DOWN=1 ;;
    --no-seed) DO_SEED=0 ;;
    --drive)   DO_SEED=0; DO_DRIVE=1 ;;
    *) die "unknown arg '$1' (usage: run-tap-demo.sh [--an536] [--drive|--no-seed|--down])" ;;
  esac
  shift
done
select_lane
LANE_FLAG=""; [[ "${LANE}" == "an536" ]] && LANE_FLAG="--an536"
((DO_DOWN)) && { demo_down; exit 0; }

# ---- preflight ----
ip link show "${TAP_IF}" >/dev/null 2>&1 || \
  die "no ${TAP_IF} — run: sudo scripts/setup-tap.sh   (root; not run for you)"
docker info >/dev/null 2>&1 || die "docker not available."
if [[ "${LANE}" == "an536" ]]; then
  QEMU_BIN="${QEMU_BIN:-${NROS_HOME:-${HOME}/.nros}/sdk/qemu/11.0.0-nros2/bin/qemu-system-arm}"
  [[ -x "${QEMU_BIN}" ]] || QEMU_BIN="$(command -v qemu-system-arm || true)"
  [[ -x "${QEMU_BIN}" ]] || \
    die "qemu-system-arm not found — (cd modules/nros && nros setup --tool qemu) or set QEMU_BIN."
  "${QEMU_BIN}" -machine help 2>/dev/null | grep -q mps3-an536 || \
    die "${QEMU_BIN} does not know -machine mps3-an536 (needs QEMU >= 9.0)."
else
  command -v west >/dev/null 2>&1 || {
    [[ -f "${ROOT}/activate-asi.sh" ]] && source "${ROOT}/activate-asi.sh"
    command -v west >/dev/null 2>&1 || die "west not on PATH — source ./activate-asi.sh first."
  }
  if [[ -z "${ARMFVP_BIN_PATH:-}" ]]; then
    [[ -x "${ROOT}/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin/FVP_BaseR_AEMv8R" ]] || \
      die "FVP not found — set ARMFVP_BIN_PATH or install under tools/fvp/ (see tools/README.md)."
    export ARMFVP_BIN_PATH="${ROOT}/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin"
  fi
fi
mkdir -p "${LOG_DIR}"

# ---- build (incremental; no-op when up to date) ----
# cache_state_modelled=0 is REQUIRED for interactive runs: with the default =1
# the model crawls ~1000x under busy code (W3 runbook). Baked at build time.
say "building the ${LANE} island image (incremental)…"
if [[ "${LANE}" == "an536" ]]; then
  # NROS_DOMAIN_ID=2 is load-bearing: the demo bridges Autoware (domain 1) to
  # the island (domain 2), and the bringup's [deploy.an536].domain_id does not
  # reach this lane (nano-ros issue 0831) — this knob is what actually bakes it.
  ( cd "${ROOT}" && NROS_DOMAIN_ID=2 ./build.sh --platform freertos-an536 ) \
    > "${LOG_DIR}/tap-demo-build.log" 2>&1 || die "build failed — see ${LOG_DIR}/tap-demo-build.log"
else
  export ARMFVP_EXTRA_FLAGS="${ARMFVP_EXTRA_FLAGS:-} -C cache_state_modelled=0"
  # ASI_DEMO_BUILD_ARGS — extra build.sh flags for the island image. Added for
  # the phase-7 loaded capture: `ASI_DEMO_BUILD_ARGS=--trace` builds the tracing
  # profile, so a CTF timeline can be taken WHILE the vehicle drives rather than
  # only on an idle island. Word-split on purpose (multiple flags).
  # shellcheck disable=SC2086
  ( cd "${ROOT}" && ./build.sh --platform zephyr-fvp --network tap -d "${BUILD_DIR}" \
      ${ASI_DEMO_BUILD_ARGS:-} ) \
    > "${LOG_DIR}/tap-demo-build.log" 2>&1 || die "build failed — see ${LOG_DIR}/tap-demo-build.log"
fi

# ---- island + compose, in the order the lane needs ----
# an536 boots the island FIRST. Booting the ASI image into an ALREADY RUNNING
# domain-2 graph fails at create_subscription ("rmw_ret error", code=-100) and
# then trips a heap_4 assert; the same image boots clean with no peer and
# survives a peer joining later. So: island, then stack. (ASI issue: see
# documentation/roadmap/phase-6, "boot into an existing graph".)
start_compose() {
  say "starting demo compose stack (DDS domain 2 on ${TAP_IF})…"
  ( cd "${ROOT}/demo" && docker compose "${COMPOSE_FILES[@]}" up -d )
}

# Reuse an island that is already up and past its boot marker — iterating on a
# mission should not cost a reboot, and on an536 a reboot into a live graph is
# exactly the thing that fails.
island_already_up() {
  [[ "${LANE}" == "an536" ]] || return 1
  pgrep -f "qemu-system-arm -machine mps3-an536" >/dev/null 2>&1 || return 1
  grep -q "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null || return 1
  return 0
}

# The island has no RTC and no route off the tap, so its wall clock comes from
# this responder on the tap host. Without it every control command is stamped
# boot-relative, Autoware's operation-mode manager publishes no state, and
# autonomous mode can never be engaged (the FVP lane needs the same thing).
start_sntp() {
  if pgrep -f "sntp-server.py --bind ${TAP_HOST_IP}" >/dev/null 2>&1; then
    say "SNTP responder already running on ${TAP_HOST_IP}:${SNTP_PORT}."
    return 0
  fi
  say "starting SNTP responder on ${TAP_HOST_IP}:${SNTP_PORT}…"
  nohup python3 "${ROOT}/scripts/sntp-server.py" \
    --bind "${TAP_HOST_IP}" --port "${SNTP_PORT}" > "${LOG_DIR}/tap-demo-sntp.log" 2>&1 &
  echo "$!" > "${SNTP_PID_FILE}"
  disown $! 2>/dev/null || true
}

if [[ "${LANE}" == "an536" ]]; then
  start_sntp
  if island_already_up; then
    say "reusing the island already running (log: ${ISLAND_LOG})."
  else
    # ---- boot the island ----
say "booting the island on ${LANE} (log: ${ISLAND_LOG})…"
rm -f "${ISLAND_LOG}"
# Plain background + disown — a `( cmd & echo $! )` subshell here once left
# west as a FOREGROUND child (bash subshell fork optimization: `$!` was the
# script's own pid) and the script sat in wait() forever.
if [[ "${LANE}" == "an536" ]]; then
  ISLAND_ELF="${BUILD_DIR}/src/freertos_an536_entry/actuation_an536_entry"
  [[ -f "${ISLAND_ELF}" ]] || die "no image at ${ISLAND_ELF} — build failed?"
  if pgrep -f "qemu-system-arm -machine mps3-an536" >/dev/null 2>&1; then
    die "a QEMU already holds ${TAP_IF} — run: scripts/run-tap-demo.sh --an536 --down"
  fi
  # -netdev hubport is NOT optional. With only the NIC and the tap on QEMU's
  # hub, host-to-guest frames are never delivered: the island publishes and
  # never receives, so Autoware sees control commands while the island holds
  # safe stop forever (nano-ros issue 0830).
  nohup "${QEMU_BIN}" -machine mps3-an536 -nographic \
    -semihosting-config enable=on,target=native -kernel "${ISLAND_ELF}" \
    -net nic -net tap,ifname="${TAP_IF}",script=no,downscript=no \
    -netdev hubport,id=h0,hubid=0 > "${ISLAND_LOG}" 2>&1 &
else
  # build.sh --run, NOT `west build --target run`. West's run target rebuilds
  # first, and that rebuild re-enters cargo: it waits on the shared
  # ~/.cargo package-cache lock, which another agent's build or test can hold
  # for minutes. The model then never starts inside BOOT_TIMEOUT_S, and the
  # failure reads as an island that never boots. `build.sh --run` launches the
  # recorded run_armfvp command without touching the build graph, which is the
  # same fix .github/scripts/run-zephyr-fvp-ci.sh already has (a83fa1f). The
  # model's command line carries the ELF path, so demo_down's stray sweep still
  # finds it.
  nohup "${ROOT}/build.sh" --platform zephyr-fvp -d "${BUILD_DIR}" --run \
    > "${ISLAND_LOG}" 2>&1 &
fi
ISLAND_PID=$!
disown "${ISLAND_PID}" 2>/dev/null || true
echo "${ISLAND_PID}" > "${ISLAND_PID_FILE}"
for ((i = 0; i < BOOT_TIMEOUT_S; i++)); do
  grep -q "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null && break
  kill -0 "${ISLAND_PID}" 2>/dev/null || die "island exited early — see ${ISLAND_LOG}"
  sleep 1
done
grep -q "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null || \
  die "no '${BOOT_MARKER}' within ${BOOT_TIMEOUT_S}s — see ${ISLAND_LOG}"
say "island is live."
  fi
  start_compose
else
  start_sntp
  start_compose
  # ---- boot the island ----
say "booting the island on ${LANE} (log: ${ISLAND_LOG})…"
rm -f "${ISLAND_LOG}"
# Plain background + disown — a `( cmd & echo $! )` subshell here once left
# west as a FOREGROUND child (bash subshell fork optimization: `$!` was the
# script's own pid) and the script sat in wait() forever.
if [[ "${LANE}" == "an536" ]]; then
  ISLAND_ELF="${BUILD_DIR}/src/freertos_an536_entry/actuation_an536_entry"
  [[ -f "${ISLAND_ELF}" ]] || die "no image at ${ISLAND_ELF} — build failed?"
  if pgrep -f "qemu-system-arm -machine mps3-an536" >/dev/null 2>&1; then
    die "a QEMU already holds ${TAP_IF} — run: scripts/run-tap-demo.sh --an536 --down"
  fi
  # -netdev hubport is NOT optional. With only the NIC and the tap on QEMU's
  # hub, host-to-guest frames are never delivered: the island publishes and
  # never receives, so Autoware sees control commands while the island holds
  # safe stop forever (nano-ros issue 0830).
  nohup "${QEMU_BIN}" -machine mps3-an536 -nographic \
    -semihosting-config enable=on,target=native -kernel "${ISLAND_ELF}" \
    -net nic -net tap,ifname="${TAP_IF}",script=no,downscript=no \
    -netdev hubport,id=h0,hubid=0 > "${ISLAND_LOG}" 2>&1 &
else
  # build.sh --run, NOT `west build --target run`. West's run target rebuilds
  # first, and that rebuild re-enters cargo: it waits on the shared
  # ~/.cargo package-cache lock, which another agent's build or test can hold
  # for minutes. The model then never starts inside BOOT_TIMEOUT_S, and the
  # failure reads as an island that never boots. `build.sh --run` launches the
  # recorded run_armfvp command without touching the build graph, which is the
  # same fix .github/scripts/run-zephyr-fvp-ci.sh already has (a83fa1f). The
  # model's command line carries the ELF path, so demo_down's stray sweep still
  # finds it.
  nohup "${ROOT}/build.sh" --platform zephyr-fvp -d "${BUILD_DIR}" --run \
    > "${ISLAND_LOG}" 2>&1 &
fi
ISLAND_PID=$!
disown "${ISLAND_PID}" 2>/dev/null || true
echo "${ISLAND_PID}" > "${ISLAND_PID_FILE}"
for ((i = 0; i < BOOT_TIMEOUT_S; i++)); do
  grep -q "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null && break
  kill -0 "${ISLAND_PID}" 2>/dev/null || die "island exited early — see ${ISLAND_LOG}"
  sleep 1
done
grep -q "${BOOT_MARKER}" "${ISLAND_LOG}" 2>/dev/null || \
  die "no '${BOOT_MARKER}' within ${BOOT_TIMEOUT_S}s — see ${ISLAND_LOG}"
say "island is live."
fi

# ---- seed ego + goal ----
# Seeding is FEEDBACK-DRIVEN (fix shared with run-posix-demo.sh): a pose
# published before the sim can consume it is silently lost — /initialpose
# EXISTING is not readiness. Pose is accepted when /localization/
# kinematic_state starts publishing; the goal when the planner emits a
# trajectory. Retry each until its effect is observed.
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
    if in_autoware "timeout 8 ros2 topic echo --once /planning/trajectory >/dev/null 2>&1"; then
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

# ---- autonomous driving mission (--drive) ----
# shellcheck source=scripts/demo-drive-mission.sh
source "${ROOT}/scripts/demo-drive-mission.sh"
if ((DO_DRIVE)); then
  drive_mission
fi

# ---- verify the closed loop ----
say "verifying control_cmd on domain 1 (island MPC+PID → bridge)…"
HZ_OUT="$(in_autoware "timeout 25 ros2 topic hz /control/trajectory_follower/control_cmd 2>&1 | tail -4" || true)"
echo "${HZ_OUT}"
if echo "${HZ_OUT}" | grep -q "average rate"; then
  say "CLOSED LOOP OK — healthy is ~19 Hz+ (faster in the emergency-stop state). Island keeps running;"
  say "  stop everything:  scripts/run-tap-demo.sh ${LANE_FLAG} --down"
  say "  island log:       tail -f ${ISLAND_LOG}"
else
  die "no control_cmd traffic — island log: ${ISLAND_LOG}; bridge: docker logs demo-safety-island-bridge-1"
fi
