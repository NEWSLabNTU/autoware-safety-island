#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# island-run.sh -- the Safety Island side of the CARLA run, inside the L4
# runner container (L4SI_ISLAND_CMD; island-up.sh starts it in a process group
# of its own with the ego's ROS environment from `swb seat env 0`, and stops
# that group at the end).
#
# Starts, all in this process group:
#   - domain_bridge: the demo's topic contract (demo/bridge/bridge-config.yaml)
#     between the ego's domain and the island's (ASI_ISLAND_DOMAIN), every
#     domain-2 writer capped at 1400 B (demo/bridge/cyclonedds-domain2.xml);
#   - island-monitor.py on the ego's domain (what island-check.sh judges),
#     also the operator re-enable before the drive (see its docstring);
#   - a rosbag2 recording of both control_cmd topics on the ego's domain
#     (island-bag/), the rate check's cross-check;
#   - the island (build/carla-island, staged by run-carla.sh), in the
#     foreground; its output is island-up.sh's island.log.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
asi="$(cd "$here/../.." && pwd)"
state="${L4SI_STATE:?island-up.sh sets L4SI_STATE}"
ego_domain="${ROS_DOMAIN_ID:?island-up.sh sets the ego domain}"
island_domain="${ASI_ISLAND_DOMAIN:-20}"
swb_profile="${CYCLONEDDS_URI:?island-up.sh sets the swb DDS profile}"
stage="$asi/build/carla-island"

[ -x "$stage/actuation_posix_entry" ] || { echo "no staged island at $stage (run run-carla.sh)" >&2; exit 3; }
[ "$island_domain" != "$ego_domain" ] || { echo "ASI_ISLAND_DOMAIN equals the ego domain" >&2; exit 3; }

# The bridge contract with the demo's domains (1 = Autoware, 2 = island) moved
# to the ego's and the island's.
sed -e "s/from_domain: 1/from_domain: EGO/; s/to_domain: 1/to_domain: EGO/" \
    -e "s/from_domain: 2/from_domain: $island_domain/; s/to_domain: 2/to_domain: $island_domain/" \
    -e "s/EGO/$ego_domain/" \
    "$asi/demo/bridge/bridge-config.yaml" >"$state/island-bridge-config.yaml"
# The 1400 B cap, on the island's domain.
sed "s/<Domain id=\"2\">/<Domain id=\"$island_domain\">/" \
    "$asi/demo/bridge/cyclonedds-domain2.xml" >"$state/island-domain.xml"
uri="$swb_profile,file://$state/island-domain.xml"

echo "[island-run] ego domain $ego_domain, island domain $island_domain"
CYCLONEDDS_URI="$uri" ros2 run domain_bridge domain_bridge "$state/island-bridge-config.yaml" \
    >"$state/island-bridge.log" 2>&1 </dev/null &
echo "[island-run] domain_bridge pid $!"
CYCLONEDDS_URI="$uri" python3 "$here/island-monitor.py" "$state/island-monitor.jsonl" "$state/island.log" "$island_domain" \
    >"$state/island-monitor.log" 2>&1 </dev/null &
echo "[island-run] monitor pid $!"
# A second, independent count of the island's control_cmd on the ego's domain:
# rosbag2's C++ recorder (receive timestamps), next to the Python monitor.
ros2 bag record -s mcap -o "$state/island-bag" \
    /control/trajectory_follower/control_cmd /control/command/control_cmd \
    /api/operation_mode/state >"$state/island-bag.log" 2>&1 </dev/null &
echo "[island-run] bag recorder pid $!"

# The island: a host process reading its domain and DDS profile from the
# environment (nano-ros hosted env-rung), libddsc staged beside it.
export ROS_DOMAIN_ID="$island_domain" CYCLONEDDS_URI="$uri"
export LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$stage/actuation_posix_entry"
