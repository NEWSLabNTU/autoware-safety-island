#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# demo-drive-mission.sh - the --drive mission shared by run-tap-demo.sh and
# run-posix-demo.sh. Sourced, not run. The caller defines ROOT,
# AUTOWARE_CTR, ISLAND_LOG and the say / warn / die / in_autoware helpers,
# then calls drive_mission.

# ---- autonomous driving mission (--drive) ----
# Distinct from the callers' seed_ego_and_goal, which only exercises the
# EMERGENCY-STOP loop: its fixed seed is off the lane Autoware 2.0.0 plans
# (5.3 m, heading 102 deg against the lane's 92 deg), so the island's MPC
# refuses it ("too large position error"). A driving mission needs
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
#     runaway. Autoware 2.0.0 returns to STOP by itself on arrival (measured
#     with run-posix-demo.sh --drive); the explicit call stays for the images
#     that do not.
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
       --map /autoware_map/lanelet2_map.osm \
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
    if in_autoware "timeout 8 ros2 topic echo --once /planning/trajectory \
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
    die "vehicle never moved — island log: ${ISLAND_LOG}"
  fi
}
