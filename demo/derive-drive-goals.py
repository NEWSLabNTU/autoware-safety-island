#!/usr/bin/env python3
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# derive-drive-goals.py — pick a driving mission off the lanelet2 map.
#
# WHY. `run-tap-demo.sh --drive` used hand-probed coordinates: a spawn pose and
# a list of goals found by trying `set_route_points` until the planner accepted
# one. That only ever worked on sample-map-planning, and only from the one spawn
# it was probed at — the numbers carry no meaning, so nobody can move the demo to
# another map or another part of this one without repeating the probing.
#
# This derives them instead. A driving mission needs a spawn ON a lane WITH the
# lane's heading (off-lane or mis-headed and the planner emits a goal-anchored
# zero-velocity sliver the island correctly refuses), and a goal that is
# reachable by following lanes — which is exactly what a routing graph answers.
#
# Runs INSIDE the Autoware container (lanelet2 python bindings + the map mount);
# the demo script invokes it through `docker exec` and reads the poses off
# stdout. Emits shell-friendly lines:
#
#   SPAWN <x> <y> <qz> <qw>
#   GOAL <distance_m> <x> <y> <qz> <qw>     (one per requested distance)
#
# Distances are ARC LENGTH along the lane centerlines, not straight-line, so a
# curved route still gets the mission length it was asked for.

import argparse
import math
import re
import sys

import lanelet2
from lanelet2.projection import UtmProjector

# MGRS 100 km square lettering. Column letters run in three repeating sets of
# eight (I and O are never used); row letters run through a 20-letter cycle that
# is offset by half in even-numbered zones.
_COL_SETS = ("ABCDEFGH", "JKLMNPQR", "STUVWXYZ")
_ROW_LETTERS = "ABCDEFGHJKLMNPQRSTUV"
_BAND_LETTERS = "CDEFGHJKLMNPQRSTUVWX"  # 8 degrees each, starting at -80


def mgrs_square_origin(grid, pyproj):
    """UTM easting/northing of a 100 km square's south-west corner.

    Autoware's MGRS map frame is metres from this corner, so this is the whole
    difference between lanelet2's UTM output and the coordinates the running
    stack uses. Computed from the grid code rather than tabulated, so any MGRS
    map works, not just the one this demo ships.
    """
    m = re.match(r"^(\d{1,2})([C-X])([A-Z])([A-Z])$", grid.strip().upper())
    if not m:
        raise ValueError("not an MGRS 100 km square code: %r" % grid)
    zone, band, col, row = int(m.group(1)), m.group(2), m.group(3), m.group(4)

    cols = _COL_SETS[(zone - 1) % 3]
    if col not in cols:
        raise ValueError("column letter %s is not valid in zone %d" % (col, zone))
    easting0 = (cols.index(col) + 1) * 100000.0

    # Even zones start the row cycle half way through it.
    start = 0 if zone % 2 == 1 else 5
    row_offset = ((_ROW_LETTERS.index(row) - start) % 20) * 100000.0

    # The row cycle repeats every 2 000 km; the latitude band picks the repeat.
    band_lat = -80.0 + 8.0 * _BAND_LETTERS.index(band)
    north = pyproj.Proj(proj="utm", zone=zone, ellps="WGS84", south=False)
    for k in range(0, 11):
        northing0 = row_offset + k * 2000000.0
        lon, lat = north(easting0 + 50000.0, northing0 + 50000.0, inverse=True)
        if band_lat <= lat < band_lat + 8.0:
            return zone, easting0, northing0
    raise ValueError("no 2000 km repeat of row %s lands in band %s" % (row, band))


def first_node_latlon(map_path):
    """A reference lat/lon from the map, for an origin-relative projector."""
    with open(map_path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = re.search(r"<node[^>]*\blat=['\"]([-\d.]+)['\"][^>]*\blon=['\"]([-\d.]+)['\"]", line)
            if m:
                return float(m.group(1)), float(m.group(2))
            m = re.search(r"<node[^>]*\blon=['\"]([-\d.]+)['\"][^>]*\blat=['\"]([-\d.]+)['\"]", line)
            if m:
                return float(m.group(2)), float(m.group(1))
    raise ValueError("no <node lat= lon=> found in %s" % map_path)


def load_robust(map_path, projector):
    """Load tolerating parse errors, the way Autoware's own map loader does.

    Autoware's sample map carries regulatory elements referencing ids that are
    not in the file; a strict `io.load` refuses the whole map over them. None of
    them affect centerlines or lane connectivity, which is all this needs.
    """
    lanelet_map, errors = lanelet2.io.loadRobust(map_path, projector)
    if errors:
        print("# %d map parse errors ignored (dangling references)" % len(errors),
              file=sys.stderr)
    return lanelet_map


def load_map(map_path, projector_type, mgrs_grid, origin_lat, origin_lon):
    """Load the map and return (lanelet_map, (dx, dy)) into the Autoware frame.

    lanelet2's python bindings expose no MGRS projector (it is C++-only), so the
    map is loaded with a UTM projector anchored at a node of the map itself and
    the result is TRANSLATED into the MGRS square. Both frames are the same UTM
    zone, so the correction is a pure translation — no rotation, no scale.
    """
    if projector_type.upper() == "MGRS":
        import pyproj

        ref_lat, ref_lon = first_node_latlon(map_path)
        projector = UtmProjector(lanelet2.io.Origin(ref_lat, ref_lon))
        lanelet_map = load_robust(map_path, projector)

        zone, easting0, northing0 = mgrs_square_origin(mgrs_grid, pyproj)
        fwd = pyproj.Proj(proj="utm", zone=zone, ellps="WGS84", south=False)
        ref_e, ref_n = fwd(ref_lon, ref_lat)
        return lanelet_map, (ref_e - easting0, ref_n - northing0)

    # UTM / local-cartesian maps already declare the origin the stack uses.
    projector = UtmProjector(lanelet2.io.Origin(origin_lat, origin_lon))
    return load_robust(map_path, projector), (0.0, 0.0)


def centerline_points(lanelet, offset=(0.0, 0.0)):
    """Centerline in the Autoware map frame (see load_map for the offset)."""
    dx, dy = offset
    return [(p.x + dx, p.y + dy) for p in lanelet.centerline]


def yaw_to_quat(yaw):
    return math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def project_on_segment(px, py, x0, y0, x1, y1):
    """Closest point on segment (x0,y0)-(x1,y1), as (distance, t) with t in [0,1]."""
    dx, dy = x1 - x0, y1 - y0
    den = dx * dx + dy * dy
    t = 0.0 if den == 0.0 else ((px - x0) * dx + (py - y0) * dy) / den
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return math.hypot(px - (x0 + dx * t), py - (y0 + dy * t)), t


def nearest_lanelet(lanelet_map, x, y, offset):
    """Drivable lanelet whose centerline passes closest to (x, y).

    Projects onto the centerline SEGMENTS, not just its vertices: centerline
    vertices are metres apart, so a vertex-only search reports a spawn several
    metres off the lane and starts the walk from the wrong place.

    Returns (distance, lanelet, segment_index, t_along_segment).
    """
    best = None
    for ll in lanelet_map.laneletLayer:
        # lanelet2's AttributeMap is dict-LIKE but has no .get()
        attrs = ll.attributes
        if "subtype" not in attrs or str(attrs["subtype"]) != "road":
            continue
        pts = centerline_points(ll, offset)
        for i in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[i], pts[i + 1]
            d, t = project_on_segment(x, y, x0, y0, x1, y1)
            if best is None or d < best[0]:
                best = (d, ll, i, t)
    return best


def walk(graph, start_ll, start_idx, start_t, distances, offset):
    """Walk centerlines forward from the spawn, sampling at each distance.

    Follows the routing graph's first successor at each lanelet end, so the
    resulting goals are reachable by a route rather than merely nearby in space.
    Distances are arc length from the spawn point (not from the segment vertex
    behind it), so a mission asked for 20 m is 20 m of driving.
    """
    want = sorted(distances)
    out = {}
    ll = start_ll
    idx = start_idx
    frac = start_t
    travelled = 0.0
    guard = 0

    while want and guard < 10000:
        guard += 1
        pts = centerline_points(ll, offset)
        while idx + 1 < len(pts) and want:
            (x0, y0), (x1, y1) = pts[idx], pts[idx + 1]
            full = math.hypot(x1 - x0, y1 - y0)
            seg = full * (1.0 - frac)  # remainder of the segment we start inside
            while want and travelled + seg >= want[0]:
                need = want.pop(0)
                along = frac + (0.0 if full == 0 else (need - travelled) / full)
                gx = x0 + (x1 - x0) * along
                gy = y0 + (y1 - y0) * along
                out[need] = (gx, gy, math.atan2(y1 - y0, x1 - x0))
            travelled += seg
            frac = 0.0
            idx += 1
        if not want:
            break
        nxt = graph.following(ll)
        if not nxt:
            break  # end of the routable lane: whatever is left is unreachable
        ll = nxt[0]
        idx = 0
        frac = 0.0

    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True)
    ap.add_argument("--projector", default="MGRS")
    ap.add_argument("--mgrs-grid", default="")
    ap.add_argument("--origin-lat", type=float, default=0.0)
    ap.add_argument("--origin-lon", type=float, default=0.0)
    ap.add_argument("--near-x", type=float, required=True,
                    help="rough point to start from; snapped onto the nearest road lanelet")
    ap.add_argument("--near-y", type=float, required=True)
    ap.add_argument("--distances", default="20,14,10",
                    help="goal arc lengths in metres, farthest first is fine")
    args = ap.parse_args()

    lanelet_map, offset = load_map(args.map, args.projector, args.mgrs_grid,
                                   args.origin_lat, args.origin_lon)

    found = nearest_lanelet(lanelet_map, args.near_x, args.near_y, offset)
    if found is None:
        print("ERROR no road lanelet in the map", file=sys.stderr)
        return 1
    dist, start_ll, start_idx, start_t = found

    pts = centerline_points(start_ll, offset)
    # Spawn ON the centerline, headed along it — the two properties the planner
    # needs and a hand-picked pose usually misses.
    (x0, y0), (x1, y1) = pts[start_idx], pts[start_idx + 1]
    sx = x0 + (x1 - x0) * start_t
    sy = y0 + (y1 - y0) * start_t
    syaw = math.atan2(y1 - y0, x1 - x0)
    qz, qw = yaw_to_quat(syaw)
    print("SPAWN %.3f %.3f %.6f %.6f" % (sx, sy, qz, qw))

    rules = lanelet2.traffic_rules.create(lanelet2.traffic_rules.Locations.Germany,
                                          lanelet2.traffic_rules.Participants.Vehicle)
    graph = lanelet2.routing.RoutingGraph(lanelet_map, rules)

    wanted = [float(d) for d in args.distances.split(",") if d.strip()]
    goals = walk(graph, start_ll, start_idx, start_t, wanted, offset)
    if not goals:
        print("ERROR no goal reachable along the lane", file=sys.stderr)
        return 1

    # Farthest first: the demo tries them in order and takes the first the
    # planner accepts, so the longest feasible mission wins.
    for d in sorted(goals, reverse=True):
        gx, gy, gyaw = goals[d]
        gqz, gqw = yaw_to_quat(gyaw)
        print("GOAL %.1f %.3f %.3f %.6f %.6f" % (d, gx, gy, gqz, gqw))

    print("# snapped %.2f m onto lanelet %d" % (dist, start_ll.id), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
