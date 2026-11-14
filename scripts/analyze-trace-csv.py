#!/usr/bin/env python3
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
"""Analyse an execution-segment trace, either lane.

Input is the common CSV both lanes now emit -- `task,start_us,end_us`, one row
per contiguous execution segment on a single core:

  Zephyr FVP   scripts/parse-zephyr-ctf.py --csv OUT/
  FreeRTOS     scripts/trace2csv-freertos.py RUNDIR/   (Tonbandgeraet snapshot)

An optional `trace_meta.json` beside it carries what the CSV cannot express:
`load`/`flood_hz` for the FreeRTOS lane, and for a lane whose clock is not
elapsed time, `wall_clock_span_valid: false` plus a `busy_span_us` to use in
its place. The FVP fast-forwards through WFI, so its wall span is inflated
and occupancy must be taken against busy time; see write_trace_meta() in
parse-zephyr-ctf.py.

Reports, per task: occupancy, slice-duration distribution, activation period
and its jitter, and preemption (an activation split across several segments).
Nothing here is lane-specific -- the point is that the two lanes are
comparable at all.
"""

import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

# Two segments of the same task separated by less than this are treated as one
# activation that was preempted, rather than two arrivals. The FreeRTOS tiers
# run at 1 kHz (1000 us period), so this must stay well under that; the Zephyr
# executor wakes every 6 ms. 200 us splits both without ambiguity.
PREEMPT_GAP_US = 200.0

# A task whose share of busy time is below this is reported but excluded from
# period analysis: a handful of segments gives a meaningless distribution.
MIN_SEGMENTS_FOR_PERIOD = 8


def pct(sorted_vals, q):
    """Percentile by nearest rank; sorted_vals must be non-empty."""
    if not sorted_vals:
        return float("nan")
    i = min(len(sorted_vals) - 1, int(q * len(sorted_vals)))
    return sorted_vals[i]


def load(rundir):
    path = Path(rundir) / "trace.csv"
    if not path.exists():
        path = Path(rundir)          # allow passing the CSV directly
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            rows.append((r["task"], float(r["start_us"]), float(r["end_us"])))
    rows.sort(key=lambda t: t[1])

    meta = {}
    mpath = Path(rundir) / "trace_meta.json"
    if mpath.exists():
        meta = json.loads(mpath.read_text())
    return rows, meta


def activations(segs):
    """Coalesce a task's segments into activations.

    Returns (activation_list, preempt_gap_list) where an activation is
    (start_us, end_us, exec_us, n_segments). exec_us is time actually on the
    core; end-start is wall time, and the difference is preemption.
    """
    acts, gaps = [], []
    cur_start = cur_end = None
    cur_exec = 0.0
    cur_n = 0
    for _, a, b in segs:
        if cur_start is None:
            cur_start, cur_end, cur_exec, cur_n = a, b, b - a, 1
            continue
        if a - cur_end <= PREEMPT_GAP_US:
            gaps.append(a - cur_end)
            cur_end, cur_exec, cur_n = b, cur_exec + (b - a), cur_n + 1
        else:
            acts.append((cur_start, cur_end, cur_exec, cur_n))
            cur_start, cur_end, cur_exec, cur_n = a, b, b - a, 1
    if cur_start is not None:
        acts.append((cur_start, cur_end, cur_exec, cur_n))
    return acts, gaps


def analyse(rundir, since_s=0.0, until_s=None):
    rows, meta = load(rundir)
    if not rows:
        return None

    # Clip to the regime of interest. Offsets are seconds from the first
    # segment, and a segment straddling a boundary is truncated to it so the
    # occupancy arithmetic stays exact.
    if since_s or until_s is not None:
        base = min(a for _, a, _ in rows)
        lo = base + since_s * 1e6
        hi = base + until_s * 1e6 if until_s is not None else float("inf")
        rows = [(t, max(a, lo), min(b, hi)) for t, a, b in rows
                if b > lo and a < hi]
        if not rows:
            return None
        # The stored busy_span_us describes the whole capture, so it no
        # longer applies; recompute it over the window.
        if not meta.get("wall_clock_span_valid", True):
            meta = dict(meta)
            meta["busy_span_us"] = sum(
                b - a for t, a, b in rows if not t.startswith("idle"))
        meta = dict(meta, window_since_s=since_s, window_until_s=until_s)

    t0 = min(a for _, a, _ in rows)
    t1 = max(b for _, _, b in rows)
    wall_span = t1 - t0
    # Careful with the word "busy": this is every segment including the idle
    # thread, whereas trace_meta's busy_span_us excludes idle. On the TAP
    # capture they are 83533 ms and 65284 ms -- printing both as "busy" was
    # actively misleading, so they are named apart here.
    on_core = sum(b - a for _, a, b in rows)
    non_idle = sum(b - a for t, a, b in rows if not t.startswith("idle"))

    basis, span = "wall", wall_span
    if not meta.get("wall_clock_span_valid", True):
        span = meta.get("busy_span_us")
        basis = "busy" if span else "invalid"

    by_task = defaultdict(list)
    for t, a, b in rows:
        by_task[t].append((t, a, b))

    tasks = {}
    for name, segs in by_task.items():
        durs = sorted(b - a for _, a, b in segs)
        acts, gaps = activations(segs)
        starts = [x[0] for x in acts]
        periods = sorted(y - x for x, y in zip(starts, starts[1:]))
        exec_us = sorted(x[2] for x in acts)
        resp_us = sorted(x[1] - x[0] for x in acts)
        preempted = sum(1 for x in acts if x[3] > 1)
        tasks[name] = {
            "segments": len(segs),
            "busy_us": sum(durs),
            "slice_p50": pct(durs, 0.50),
            "slice_p99": pct(durs, 0.99),
            "slice_max": durs[-1],
            "activations": len(acts),
            "preempted": preempted,
            "preempt_pct": 100.0 * preempted / len(acts) if acts else 0.0,
            "period_p50": pct(periods, 0.50) if periods else None,
            "period_p99": pct(periods, 0.99) if periods else None,
            "period_max": periods[-1] if periods else None,
            "period_min": periods[0] if periods else None,
            "exec_p50": pct(exec_us, 0.50),
            "exec_max": exec_us[-1],
            "resp_max": resp_us[-1],
            "enough": len(acts) >= MIN_SEGMENTS_FOR_PERIOD,
        }

    # Context switches = transitions between different tasks in time order.
    switches = sum(1 for x, y in zip(rows, rows[1:]) if x[0] != y[0])

    # Gaps in the timeline: no task recorded as executing. On the Zephyr lane
    # these are the WFI stretches; on FreeRTOS the fold has no gaps by
    # construction (a task runs until the next switch-in).
    dead = 0.0
    last = t0
    for _, a, b in rows:
        if a > last:
            dead += a - last
        last = max(last, b)

    return {
        "rundir": str(rundir),
        "meta": meta,
        "wall_span_us": wall_span,
        "on_core_us": on_core,
        "non_idle_us": non_idle,
        "span_us": span,
        "basis": basis,
        "unaccounted_us": dead,
        "segments": len(rows),
        "switches": switches,
        "tasks": tasks,
    }


def report(r):
    name = Path(r["rundir"]).name
    m = r["meta"]
    print(f"=== {name} " + "=" * max(0, 60 - len(name)))
    if m.get("window_since_s") or m.get("window_until_s") is not None:
        print(f"  window         t={m.get('window_since_s', 0):g} s .. "
              f"{m.get('window_until_s') if m.get('window_until_s') is not None else 'end'}")
    load = m.get("load")
    if load is not None:
        print(f"  load           {load} flood generators "
              f"({m.get('flood_hz', '?')} msg/s)")
    print(f"  wall span      {r['wall_span_us'] / 1e3:12.3f} ms")
    print(f"  on core        {r['on_core_us'] / 1e3:12.3f} ms  (all threads)")
    print(f"  non-idle       {r['non_idle_us'] / 1e3:12.3f} ms  (idle excluded)")
    if r["unaccounted_us"] > 0:
        print(f"  unaccounted    {r['unaccounted_us'] / 1e3:12.3f} ms "
              f"({100 * r['unaccounted_us'] / r['wall_span_us']:.1f}% of wall)")
    print(f"  segments       {r['segments']:12d}   switches {r['switches']}")
    if r["basis"] != "wall":
        print(f"  occupancy vs   {r['basis']} span "
              f"({r['span_us'] / 1e3:.3f} ms) -- wall clock declared invalid")
    print()
    hdr = (f"  {'task':<26}{'occ%':>7}{'segs':>7}{'acts':>7}"
           f"{'slice p50':>11}{'slice max':>11}{'per p50':>10}{'per max':>10}"
           f"{'preempt%':>10}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    order = sorted(r["tasks"].items(), key=lambda kv: -kv[1]["busy_us"])
    for t, d in order:
        if r["basis"] == "busy" and t.startswith("idle"):
            occ = "  --"          # idle over a busy denominator means nothing
        elif r["span_us"]:
            occ = f"{100 * d['busy_us'] / r['span_us']:6.2f}"
        else:
            occ = "   ?"
        p50 = f"{d['period_p50'] / 1e3:9.3f}" if d["period_p50"] and d["enough"] else "        -"
        pmx = f"{d['period_max'] / 1e3:9.3f}" if d["period_max"] and d["enough"] else "        -"
        print(f"  {t:<26}{occ:>7}{d['segments']:>7}{d['activations']:>7}"
              f"{d['slice_p50']:>10.1f}u{d['slice_max']:>10.1f}u"
              f"{p50:>10}{pmx:>10}{d['preempt_pct']:>9.1f}%")
    print()


def main():
    args, since, until = [], 0.0, None
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--since":
            since = float(next(it))
        elif a == "--until":
            until = float(next(it))
        else:
            args.append(a)
    if not args:
        sys.exit("usage: analyze-trace-csv.py [--since S] [--until S] "
                 "<rundir> [rundir ...]")
    for d in args:
        r = analyse(d, since, until)
        if r is None:
            print(f"=== {Path(d).name}: empty")
            continue
        report(r)


if __name__ == "__main__":
    main()
