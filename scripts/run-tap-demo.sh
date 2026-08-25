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
DO_DRIVE=0
case "${1:-}" in
  --down)    demo_down; exit 0 ;;
  --no-seed) DO_SEED=0 ;;
  --drive)   DO_SEED=0; DO_DRIVE=1 ;;
  "")        ;;
  *) die "unknown arg '$1' (usage: run-tap-demo.sh [--drive|--no-seed|--down])" ;;
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

# ---- autonomous driving mission (--drive) ----
# Distinct from seed_ego_and_goal above, which only ever exercises the
# EMERGENCY-STOP loop (see the seed note at the top). A driving mission needs
# three things the bare-topic seed does not do:
#   * a LANE-CONSISTENT spawn: an on-lane point with the LANE's heading, or the
#     planner emits a goal-anchored zero-velocity sliver the island rightly
#     refuses ("too large position error");
#   * the route set through ADAPI `set_route_points`, not by publishing
#     /planning/mission_planning/goal — the bare topic leaves ADAPI's
#     route_state UNSET, which reds component_state_diagnostics: route_state
#     and makes autonomous mode unavailable;
#   * an explicit change_to_stop the moment the mission ends: when the planner
#     stops publishing on arrival, Autoware's trajectory rate check errors, MRM
#     engages, and this image's mrm_emergency_stop_operator ramps the WRONG way
#     (vehicle_cmd_gate clamps its diverging command to 25 m/s / +4 m/s^2 and
#     the sim runs away). Host-side defect; the island commands a safe stop
#     throughout. Leaving stop mode off is what turns a finished mission into a
#     runaway.
# The mission is DERIVED from the lanelet2 map, not hand-picked (see
# demo/derive-drive-goals.py). These are the fallback poses that derivation
# replaces: the hand-probed pair this demo shipped with, kept so the demo still
# runs if the deriver cannot (no lanelet2 bindings, an unusual projector).
DRIVE_SPAWN='{header: {frame_id: map}, pose: {pose: {position: {x: 3714.44, y: 73753.15, z: 0.0}, orientation: {z: 0.25, w: 0.968}}}}'
# Goal candidates along the same lane, farthest first — the planner refuses a
# goal it cannot route to ("The planned route is empty"), and how far it will
# route varies with the lanelet the spawn landed on.
# Each entry is "x y qz qw".
DRIVE_GOALS=(
  "3730.2 73761.8 0.25 0.968"
  "3726.0 73759.5 0.25 0.968"
  "3722.0 73757.0 0.25 0.968"
)
# Where on the map to drive, and how long a mission to ask for. The point is
# only a HINT: the deriver snaps it onto the nearest lane centerline, so it
# selects an area rather than a pose. Override to move the demo elsewhere.
MAP_DIR="${MAP_DIR:-${ROOT}/demo/map/sample-map-planning}"
DRIVE_NEAR_X="${DRIVE_NEAR_X:-3714.44}"
DRIVE_NEAR_Y="${DRIVE_NEAR_Y:-73753.15}"
DRIVE_DISTANCES="${DRIVE_DISTANCES:-30,20,14,10}"

# Replace the fallbacks above with poses derived from the map's own geometry:
# a spawn on a lane centerline headed along it, and goals at arc-length
# distances reachable by following the routing graph. Runs inside the Autoware
# container because that is where the lanelet2 python bindings live.
derive_mission() {
  local proj grid out spawn_set=0
  [[ -f "${MAP_DIR}/map_projector_info.yaml" ]] || { warn "no map_projector_info.yaml under ${MAP_DIR}"; return 1; }
  proj="$(awk '/projector_type:/ {print $2}' "${MAP_DIR}/map_projector_info.yaml")"
  grid="$(awk '/mgrs_grid:/ {print $2}' "${MAP_DIR}/map_projector_info.yaml")"
  docker cp "${ROOT}/demo/derive-drive-goals.py" \
    "${AUTOWARE_CTR}:/tmp/derive-drive-goals.py" >/dev/null 2>&1 || return 1

  out="$(docker exec "${AUTOWARE_CTR}" bash -c \
    "source /opt/autoware/setup.bash 2>/dev/null; \
     python3 /tmp/derive-drive-goals.py \
       --map /root/autoware_map/lanelet2_map.osm \
       --projector '${proj:-MGRS}' --mgrs-grid '${grid}' \
       --near-x ${DRIVE_NEAR_X} --near-y ${DRIVE_NEAR_Y} \
       --distances '${DRIVE_DISTANCES}' 2>/dev/null")" || return 1

  local kind a b c d e derived=()
  while read -r kind a b c d e; do
    case "${kind}" in
      SPAWN)
        DRIVE_SPAWN="{header: {frame_id: map}, pose: {pose: {position: {x: ${a}, y: ${b}, z: 0.0}, orientation: {z: ${c}, w: ${d}}}}}"
        spawn_set=1
        ;;
      GOAL) derived+=("${b} ${c} ${d} ${e}") ;;  # a is the distance
    esac
  done <<<"${out}"

  ((spawn_set)) && ((${#derived[@]})) || return 1
  DRIVE_GOALS=("${derived[@]}")
  say "mission derived from the map: spawn + ${#DRIVE_GOALS[@]} goal candidates (${DRIVE_DISTANCES} m)"
}

adapi_route() {  # $1 x, $2 y, $3 qz, $4 qw -> 0 on accepted
  in_autoware "timeout 15 ros2 service call /api/routing/set_route_points \
    autoware_adapi_v1_msgs/srv/SetRoutePoints \
    '{header: {frame_id: map}, goal: {position: {x: $1, y: $2, z: 0.0}, \
      orientation: {z: $3, w: $4}}}' 2>&1" | grep -q "success=True"
}

ego_speed() {
  in_autoware "timeout 5 ros2 topic echo --once /localization/kinematic_state \
    --field twist.twist.linear.x --csv 2>/dev/null" | tr -d '\r' | tail -1
}

ego_pos() {
  in_autoware "timeout 5 ros2 topic echo --once /localization/kinematic_state \
    --field pose.pose.position --csv 2>/dev/null" | tr -d '\r' | tail -1
}

route_state() {
  in_autoware "timeout 5 ros2 topic echo --once /api/routing/state --field state --csv 2>/dev/null" \
    | tr -d '\r' | tail -1
}

drive_mission() {
  say "clearing any previous route…"
  in_autoware "timeout 10 ros2 service call /api/routing/clear_route \
    autoware_adapi_v1_msgs/srv/ClearRoute {}" >/dev/null 2>&1 || true

  say "waiting for the planning sim, then spawning ego on-lane…"
  for ((i = 0; i < 60; i++)); do
    in_autoware "ros2 topic list 2>/dev/null | grep -q /initialpose" && break
    sleep 2
  done

  derive_mission || warn "map derivation unavailable — using the hand-probed fallback poses \
(valid only on sample-map-planning near ${DRIVE_NEAR_X}, ${DRIVE_NEAR_Y})"
  local ok=0
  for ((i = 0; i < 10; i++)); do
    in_autoware "ros2 topic pub --once /initialpose \
      geometry_msgs/msg/PoseWithCovarianceStamped '${DRIVE_SPAWN}'" >/dev/null
    if in_autoware "timeout 8 ros2 topic echo --once /localization/kinematic_state >/dev/null 2>&1"; then
      ok=1; break
    fi
    warn "spawn not accepted yet (attempt $((i + 1))/10) — sim still booting; retrying…"
  done
  ((ok)) || die "ego spawn never accepted — check: docker logs ${AUTOWARE_CTR}"
  say "ego at $(ego_pos)"

  local gx gy gqz gqw
  ok=0
  for g in "${DRIVE_GOALS[@]}"; do
    read -r gx gy gqz gqw <<<"${g}"
    if adapi_route "${gx}" "${gy}" "${gqz}" "${gqw}"; then
      say "route accepted to (${gx}, ${gy})"
      ok=1; break
    fi
    warn "planner refused goal (${gx}, ${gy}) — trying a nearer one…"
    in_autoware "timeout 10 ros2 service call /api/routing/clear_route \
      autoware_adapi_v1_msgs/srv/ClearRoute {}" >/dev/null 2>&1 || true
  done
  ((ok)) || die "no goal could be routed — check DRIVE_NEAR_X/Y (is the hint near a drivable lane?)."

  # A driveable trajectory carries non-zero velocities; the arrival-hold
  # sliver does not. Wait for the real thing before engaging.
  ok=0
  for ((i = 0; i < 20; i++)); do
    if in_autoware "timeout 8 ros2 topic echo --once /planning/scenario_planning/trajectory \
        2>/dev/null | grep -m1 -E 'longitudinal_velocity_mps: [1-9]' >/dev/null"; then
      ok=1; break
    fi
    sleep 2
  done
  ((ok)) || die "planner produced no driveable trajectory (all-zero velocities) — see rviz/planning logs."
  say "driveable trajectory streaming."

  ok=0
  for ((i = 0; i < 10; i++)); do
    if in_autoware "timeout 15 ros2 service call /api/operation_mode/change_to_autonomous \
        autoware_adapi_v1_msgs/srv/ChangeOperationMode {} 2>&1" | grep -q "success=True"; then
      ok=1; break
    fi
    warn "autonomous refused (attempt $((i + 1))/10) — check duplicated_node_checker and route_state; retrying…"
    sleep 3
  done
  ((ok)) || die "autonomous mode never engaged — dump: ros2 topic echo --once /system/emergency/hazard_status"
  say "ENGAGED — driving."

  # Monitor: report progress, detect arrival (route_state ARRIVED=3) or a
  # sustained stop, then IMMEDIATELY leave autonomous (see the MRM note above).
  local moved=0 still=0 vmax=0 v st
  for ((i = 0; i < 60; i++)); do
    sleep 3
    v="$(ego_speed)"; st="$(route_state)"
    [[ -n "${v}" ]] || continue
    awk -v a="${v}" -v b="${vmax}" 'BEGIN{exit !(a>b)}' && vmax="${v}"
    say "  t+$((i * 3))s  v=${v} m/s  route_state=${st}  pos=$(ego_pos)"
    awk -v a="${v}" 'BEGIN{exit !(a>0.2)}' && { moved=1; still=0; } || still=$((still + 1))
    if [[ "${st}" == "3" ]]; then
      say "ARRIVED (route_state=3)."
      break
    fi
    if ((moved && still >= 4)); then
      say "vehicle stopped and stayed stopped — treating the mission as finished."
      break
    fi
  done

  say "leaving autonomous (stop mode) before the planner goes quiet…"
  in_autoware "timeout 15 ros2 service call /api/operation_mode/change_to_stop \
    autoware_adapi_v1_msgs/srv/ChangeOperationMode {}" >/dev/null 2>&1 || true

  if ((moved)); then
    say "DRIVING MISSION OK — peak speed ${vmax} m/s, final pos $(ego_pos)"
    if [[ "$(route_state)" != "3" ]]; then
      say "  NOTE: route_state is not ARRIVED and the vehicle likely parked short."
      say "  With a MAP-DERIVED goal this does not happen (the mission reaches the"
      say "  goal within ~0.1 m). It is what a goal that is not on the lane"
      say "  centerline looks like: the planner routes to the nearest point it can"
      say "  and zeroes trajectory velocity there, and the island's departure check"
      say "  (stop point > 0.5 m ahead) then correctly holds short of the request."
      say "  Check whether derivation fell back to the hand-probed poses above."
    fi
  else
    die "vehicle never moved — island log: ${FVP_LOG}"
  fi
}
if ((DO_DRIVE)); then
  drive_mission
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
