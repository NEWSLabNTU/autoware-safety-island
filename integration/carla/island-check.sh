#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# island-check.sh -- the Safety Island's pass checks of a CARLA run
# (L4SI_ISLAND_CHECK; the L4 runner runs it after swb's suite, while the island
# still runs). Exit 0 only when every check holds:
#   1. the island drove: its log has "STOPPED -> DRIVE";
#   2. it latched no fault while driving: no "SI_STOP latched" between the
#      first AUTONOMOUS second and the last second the ego moved (on fresh
#      odometry). Latches
#      before that (the paused world before the scenario, see
#      island-monitor.py) were cleared by the operator re-enable, and are
#      listed; so are latches after the ego stopped (the world pauses again);
#   3. its control_cmd arrived on the ego's domain at >= ASI_MIN_RATE_HZ (25)
#      on average over the seconds the ego drove autonomously (> 0.5 m/s on
#      fresh odometry);
#   4. Autoware's own follower never ran: no controller_node_exe on the graph;
#   5. the gate output /control/command/control_cmd was non-zero while driving.
set -uo pipefail
state="${L4SI_STATE:?the L4 runner sets L4SI_STATE}"
min_rate="${ASI_MIN_RATE_HZ:-25}"
log="$state/island.log"
mon="$state/island-monitor.jsonl"
fail=0
ok() { echo "[island-check] PASS $*"; }
bad() { echo "[island-check] FAIL $*"; fail=1; }

[ -f "$log" ] || { bad "no island log at $log"; exit 1; }
grep -a "controller state changed" "$log" | sed 's/^/[island-check]   /'
if grep -aq "STOPPED -> DRIVE" "$log"; then ok "island entered DRIVE"; else bad "island never entered DRIVE"; fi

[ -f "$mon" ] || { bad "no monitor record at $mon"; exit 1; }
python3 - "$mon" "$min_rate" <<'PY' || fail=1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
min_rate = float(sys.argv[2])
drive = [r for i, r in enumerate(rows) if r.get("mode") == 2 and (r.get("speed") or 0) > 0.5
         and i > 0 and r.get("speed") != rows[i - 1].get("speed")]
rc = 0
def say(ok, msg):
    global rc
    print(f"[island-check] {'PASS' if ok else 'FAIL'} {msg}")
    rc |= 0 if ok else 1
say(bool(drive), f"ego drove autonomously for {len(drive)} s")
def stats(counts):
    c = sorted(counts)
    return sum(c) / len(c), c[len(c) // 2], c[0]
if drive:
    mean, p50, lo = stats([r["follower_n"] for r in drive])
    print(f"[island-check]   monitor (rclpy): mean {mean:.1f} Hz, p50 {p50}, min {lo} over {len(drive)} s")
    if any("island_n" in r for r in drive):
        imean, ip50, ilo = stats([r.get("island_n", 0) for r in drive])
        print(f"[island-check]   island domain, before the bridge: mean {imean:.1f} Hz, p50 {ip50}, min {ilo}")
    # rosbag2's C++ recorder, the same seconds: the count the check uses when present.
    bag_counts = None
    try:
        import bisect, glob, os
        import rosbag2_py
        bag = os.path.join(os.path.dirname(sys.argv[1]), "island-bag")
        if glob.glob(os.path.join(bag, "*.mcap")):
            reader = rosbag2_py.SequentialReader()
            reader.open(rosbag2_py.StorageOptions(uri=bag, storage_id="mcap"),
                        rosbag2_py.ConverterOptions("", ""))
            stamps = []
            while reader.has_next():
                topic, _, t_ns = reader.read_next()
                if topic == "/control/trajectory_follower/control_cmd":
                    stamps.append(t_ns * 1e-9)
            stamps.sort()
            bag_counts = [bisect.bisect_right(stamps, r["t"]) - bisect.bisect_right(stamps, r["t"] - 1.0)
                          for r in drive]
    except Exception as e:  # the monitor's count stands alone
        print(f"[island-check]   no bag cross-check: {e}")
    if bag_counts:
        bmean, bp50, blo = stats(bag_counts)
        print(f"[island-check]   rosbag2 (C++): mean {bmean:.1f} Hz, p50 {bp50}, min {blo}")
        mean, p50, lo, src = bmean, bp50, blo, "rosbag2"
    else:
        src = "monitor"
    say(mean >= min_rate,
        f"island control_cmd {mean:.1f} Hz while driving ({src}; p50 {p50}, min second {lo}; need >= {min_rate})")
    say(any(r["gate_vmax"] > 0.01 for r in drive),
        f"gate control_cmd non-zero while driving (max |v| {max(r['gate_vmax'] for r in drive)}, "
        f"max |steer| {max(r['gate_steer_max'] for r in drive)})")
# Latches against the drive window.
eng = next((i for i, r in enumerate(rows) if r.get("mode") == 2), None)
# The drive ends at the last second the ego moved on FRESH odometry: when swb
# ends the scenario it pauses the world, and the last speed then stays
# frozen (no new samples) while the island's watchdog sees odometry stop.
end = None
if eng is not None:
    end = eng
    for i in range(eng + 1, len(rows)):
        if rows[i].get("mode") != 2 or rows[i].get("speed") == rows[i - 1].get("speed") != 0.0:
            break
        end = i
phase = lambda i: ("before the drive" if eng is None or i < eng
                   else "while driving" if end is not None and i <= end else "after the drive")
latches = [(phase(i), e) for i, r in enumerate(rows) for e in r.get("island", [])
           if "SI_STOP latched" in e]
for where, e in latches:
    print(f"[island-check]   latch {where}: {e}")
say(not any(w == "while driving" for w, _ in latches),
    f"no SI_STOP latched while driving ({len(latches)} latch(es) in all)")
seen = [r for r in rows if r.get("follower_node") is not None]
say(bool(seen) and not any(r["follower_node"] for r in seen),
    f"no controller_node_exe on the ego graph ({len(seen)} looks)")
sys.exit(rc)
PY
exit "$fail"
