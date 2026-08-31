#!/usr/bin/env python3
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
"""Parse a Zephyr CTF trace stream into a task timeline and scheduling stats.

Standalone: reads the TSDL metadata that ships with the pinned Zephyr tree and
decodes the raw octet stream the CTF backend emits. No babeltrace2 / bt2
dependency, which matters because the FVP lane's host has neither.

Zephyr's CTF stream has no packet header and no packet context -- it is a bare
sequence of events, each `struct event_header { uint32_t timestamp; uint8_t id; }`
(little-endian, byte-aligned) followed by the event's fields. Timestamps are
nanoseconds truncated to 32 bits (subsys/tracing/ctf/ctf_top.h), so they wrap
every ~4.29 s; this script unwraps them monotonically.

Usage:
    parse-zephyr-ctf.py TRACE [-m METADATA] [--timeline] [--stats] [--limit N]
"""

import os
import argparse
import re
import bisect
import struct
import sys
from collections import Counter, defaultdict

# Fixed 20-byte character array -- `typedef struct { char buf[20]; }
# ctf_bounded_string_t` in ctf_top.h, emitted with a raw memcpy.
STRING_LEN = 20

# TSDL scalar name -> (struct format character, size in bytes).
SCALARS = {
    "uint8_t": ("B", 1),
    "int8_t": ("b", 1),
    "uint16_t": ("H", 2),
    "int16_t": ("h", 2),
    "uint32_t": ("I", 4),
    "int32_t": ("i", 4),
    "uint64_t": ("Q", 8),
    "int64_t": ("q", 8),
}

HEADER = struct.Struct("<IB")
HEADER_SIZE = HEADER.size  # 5

# A genuine 32-bit rollover shows up as a backwards jump of very nearly 2**32.
# Anything smaller is ordinary out-of-order arrival: the CTF event header has no
# CPU id, so on an SMP image events from different cores interleave and a later
# event can carry a slightly earlier timestamp. Treating those as rollovers adds
# 4.295 s each time and inflates the span enormously -- an early version of this
# script reported 18300 s for a 90 s capture.
WRAP_THRESHOLD_NS = 1 << 31

# The timestamp is 32-bit NANOSECONDS, so it wraps every 4.295 s on every
# target regardless of clock rate. That makes unwrapping ambiguous: an observed
# gap of `g` could equally be `g`, `g + 4.295 s`, or `g + 8.59 s`, and nothing
# in the stream distinguishes them. The reconstruction always assumes the
# smallest, so a long quiet stretch silently loses whole epochs.
#
# It only bites when events stop arriving for a large fraction of the period.
# Warn past half of it, and see docs/design/trace_on_hardware.rst for the fix
# (an app_marker heartbeat well inside 4.295 s makes every wrap unambiguous).
WRAP_PERIOD_NS = 1 << 32
WRAP_AMBIGUITY_WARN_NS = WRAP_PERIOD_NS // 2


def wrap_ambiguous_gaps(evs):
    """Every inter-event gap large enough to be hiding a whole epoch.

    Returned rather than only printed, because a consumer that has a
    heartbeat can reconstruct these instead of discarding the capture.
    """
    out = []
    for i, (a, b) in enumerate(zip(evs, evs[1:])):
        gap = b.ts - a.ts
        if gap > WRAP_AMBIGUITY_WARN_NS:
            out.append({
                "index": i,
                "gap_us": gap / 1e3,
                "after_event": a.name,
                "before_event": b.name,
                "at_us": a.ts / 1e3,
                # How many extra epochs would fit. The decoder assumed 0
                # extra; anything from 0 to this is consistent with the
                # stream alone.
                "epochs_assumed": 0,
                "epochs_possible_up_to": int(gap // WRAP_PERIOD_NS) + 1,
            })
    return out


def report_wrap_ambiguity(gaps):
    """Print the verdict. `gaps` from wrap_ambiguous_gaps()."""
    if not gaps:
        print(f"[wrap] no inter-event gap exceeds "
              f"{WRAP_AMBIGUITY_WARN_NS / 1e9:.3f} s; unwrapping unambiguous.")
        return
    print(f"[wrap] WARNING: {len(gaps)} inter-event gap(s) over "
          f"{WRAP_AMBIGUITY_WARN_NS / 1e9:.3f} s. The 32-bit ns timestamp "
          f"wraps every {WRAP_PERIOD_NS / 1e9:.3f} s, so each of these may be "
          f"UNDERSTATED by a multiple of that. The decoder assumed the "
          f"smallest reading (0 extra epochs) at every one:")
    for g in sorted(gaps, key=lambda d: -d["gap_us"]):
        print(f"         t={g['at_us'] / 1e6:9.3f} s  gap {g['gap_us'] / 1e3:9.3f} ms  "
              f"{g['after_event']} -> {g['before_event']}  "
              f"(0 assumed, up to {g['epochs_possible_up_to']} possible)")
    print("       Recover with --heartbeat ID:PERIOD_US rather than "
          "discarding the capture; see docs/design/trace_on_hardware.rst.")


def reconstruct_epochs_from_heartbeat(evs, marker_id, period_ns):
    """Resolve wrap ambiguity using a periodic app_marker carrying a sequence.

    The marker's `arg` must be a monotonically increasing counter. Elapsed
    time between two heartbeats is then KNOWN -- `(seq_delta) * period` --
    so a reconstruction that came out short by a multiple of the wrap period
    is missing exactly that many epochs, and the shortfall says how many.

    Compared against the PREVIOUS heartbeat, not the first: the heartbeat has
    jitter of its own, and accumulated drift against a fixed origin would
    eventually exceed half a wrap period and start inventing corrections.
    Per-interval, only one interval's jitter has to stay under 2.147 s.

    Mutates `evs` in place and returns the list of corrections applied.
    """
    HALF = WRAP_PERIOD_NS // 2
    U32 = 1 << 32
    corrections = []
    carry = 0
    prev_seq = prev_ts = None
    for e in evs:
        e.ts += carry
        if not (e.name == "app_marker"
                and e.fields.get("marker_id") == marker_id):
            continue
        seq = e.fields.get("arg")
        if seq is None:
            continue
        if prev_seq is not None:
            # u32 counter, so the delta is modular.
            d_seq = (seq - prev_seq) % U32
            expected = d_seq * period_ns
            short = expected - (e.ts - prev_ts)
            k = (short + HALF) // WRAP_PERIOD_NS   # nearest, floor-safe
            if k > 0:
                add = k * WRAP_PERIOD_NS
                carry += add
                e.ts += add
                corrections.append({
                    "at_us": prev_ts / 1e3,
                    "seq_from": prev_seq,
                    "seq_to": seq,
                    "epochs_added": int(k),
                    "recovered_us": add / 1e3,
                })
        prev_seq, prev_ts = seq, e.ts
    return corrections


class Event:
    """One decoded event: name, unwrapped timestamp (ns), and its fields.

    `disc` marks an event whose timestamp is NOT comparable with the previous
    one: the counter jumped across a WFI/idle boundary (see decode()).
    """

    __slots__ = ("name", "ts", "fields", "disc")

    def __init__(self, name, ts, fields, disc=False):
        self.name = name
        self.ts = ts
        self.fields = fields
        self.disc = disc

    def __repr__(self):
        args = " ".join(f"{k}={v}" for k, v in self.fields.items())
        return f"{self.ts / 1e6:12.6f} ms  {self.name:<28} {args}"


def parse_metadata(path):
    """Extract {event_id: (name, [(field_name, fmt, size), ...])} from TSDL.

    Only the subset Zephyr's metadata actually uses is handled: scalar
    typealiases and `ctf_bounded_string_t name[N]` arrays.
    """
    text = open(path, encoding="utf-8", errors="replace").read()
    # Strip C-style comments so a commented-out event cannot register.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)

    events = {}
    for block in re.findall(r"event\s*\{(.*?)\n\};", text, flags=re.S):
        name_m = re.search(r"name\s*=\s*(\w+)\s*;", block)
        id_m = re.search(r"id\s*=\s*(0x[0-9a-fA-F]+|\d+)\s*;", block)
        if not (name_m and id_m):
            continue
        ev_id = int(id_m.group(1), 0)
        fields = []
        body_m = re.search(r"fields\s*:=\s*struct\s*\{(.*?)\}\s*;", block, flags=re.S)
        if body_m:
            for line in body_m.group(1).splitlines():
                line = line.strip().rstrip(";").strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) < 2:
                    continue
                type_name, decl = parts[0], parts[1]
                arr = re.match(r"(\w+)\[(\d+)\]$", decl)
                if arr and type_name == "ctf_bounded_string_t":
                    fields.append((arr.group(1), "str", int(arr.group(2))))
                elif type_name in SCALARS:
                    fmt, size = SCALARS[type_name]
                    fields.append((decl, fmt, size))
                else:
                    # Unknown type: the event can no longer be decoded safely,
                    # and a wrong size desynchronises everything after it.
                    fields = None
                    break
        if fields is None:
            continue
        events[ev_id] = (name_m.group(1), fields)
    return events


def decode(blob, events):
    """Decode the raw stream. Returns (events, stats) where stats counts the
    bytes skipped during resynchronisation."""
    out = []
    pos = 0
    n = len(blob)
    skipped = 0
    # 32-bit nanosecond timestamps wrap every ~4.29 s; carry the high bits.
    epoch = 0
    last_raw = None
    last_name = None

    while pos + HEADER_SIZE <= n:
        raw_ts, ev_id = HEADER.unpack_from(blob, pos)
        spec = events.get(ev_id)
        if spec is None:
            pos += 1
            skipped += 1
            last_raw = None
            continue

        name, fields = spec
        size = sum(f[2] for f in fields)
        if pos + HEADER_SIZE + size > n:
            break

        cursor = pos + HEADER_SIZE
        values = {}
        ok = True
        for fname, fmt, fsize in fields:
            chunk = blob[cursor:cursor + fsize]
            if fmt == "str":
                text = chunk.split(b"\x00", 1)[0]
                # A name field full of non-printable bytes means we are decoding
                # garbage -- treat it as a lost-sync signal rather than emitting
                # a bogus thread name into the timeline.
                if any(b < 0x20 or b > 0x7E for b in text):
                    ok = False
                    break
                values[fname] = text.decode("ascii", "replace")
            elif fmt == "I" and fname.endswith("thread_id"):
                values[fname] = f"0x{struct.unpack('<I', chunk)[0]:08x}"
            else:
                values[fname] = struct.unpack("<" + fmt, chunk)[0]
            cursor += fsize

        if not ok:
            pos += 1
            skipped += 1
            last_raw = None
            continue

        disc = False
        if last_raw is not None and (last_raw - raw_ts) > WRAP_THRESHOLD_NS:
            epoch += 1 << 32
            # On fvp_baser_aemv8r every one of these is an `idle` followed by
            # `isr_enter`: the model advances CNTVCT across WFI by an amount
            # unrelated to guest-observable time (the tick clock the console
            # prints does not see it). Summing them as ordinary elapsed time
            # overshoots wildly -- a 12.214 s loopback run reconstructs as
            # 2654 s. Mark the boundary so callers can exclude the gap; the
            # execution time either side of it is sound.
            # FVP-specific, and WRONG on real silicon. On the model the
            # counter races ahead across WFI, so an idle-then-wrap boundary
            # spans time that never happened and the slice must go. On
            # hardware the same boundary is an ordinary rollover across a
            # genuinely idle stretch, and discarding it would throw away real
            # elapsed time. `--wall-clock-valid` says which target this is.
            disc = (last_name == "idle") and not WALL_CLOCK_VALID
        last_raw = raw_ts
        last_name = name

        out.append(Event(name, epoch + raw_ts, values, disc))
        pos = cursor

    return out, {"skipped_bytes": skipped, "trailing_bytes": n - pos}


def thread_label(ev):
    name = ev.fields.get("name")
    tid = ev.fields.get("thread_id")
    if name and tid:
        return f"{name} ({tid})"
    return name or tid or "?"


CONTRACT = None
CSV_OUT = None
SOURCE_PATH = None
# Wrap-ambiguity findings and any heartbeat corrections, recorded into
# trace_meta.json so a consumer sees them without re-running the decoder.
WRAP_GAPS = []
HEARTBEAT_FIXES = []
# False for the Arm FVP, whose counter advances during WFI at a rate unrelated
# to the tick clock. True for real silicon, where the same counter is elapsed
# time. Set by --wall-clock-valid; see docs/design/trace_on_hardware.rst.
WALL_CLOCK_VALID = False
# Which target produced the capture. Recorded in trace_meta.json so a consumer
# can tell an FVP run from silicon without being told.
LANE = "zephyr-fvp"


def write_segments_csv(runs, dropped_disc, path):
    """Emit `task,start_us,end_us` execution segments.

    The same shape nano-ros-rt-eval's FreeRTOS lane produces via
    tools/trace2csv.py, so one set of analysis tools reads both lanes.

    Two differences from that lane are deliberate and are recorded in the
    sidecar metadata rather than papered over:

      * SEGMENT ENDS ARE MEASURED, not inferred. Zephyr emits
        `thread_switched_out`, so a segment ends where the trace says it
        ends. The FreeRTOS fold has only switch-INs and must treat a task as
        running until the next one, which also forces it to drop the final
        segment. Nothing is dropped here for that reason.

      * NON-MONOTONIC TIMESTAMPS ARE DROPPED, NOT CLAMPED. The FreeRTOS port
        steps back a few microseconds across a tick boundary, and clamping
        repairs that honestly. This lane's discontinuities are WFI counter
        jumps of hundreds of milliseconds -- the FVP's counter keeps running
        while the core is halted. Clamping those would invent execution time
        that never happened, so the slices spanning them are discarded and
        counted.
    """
    import csv as _csv
    with open(path, "w", newline="") as fh:
        w = _csv.writer(fh)
        w.writerow(["task", "start_us", "end_us"])
        for start_ns, end_ns, label in sorted(runs):
            w.writerow([label, f"{start_ns / 1e3:.3f}", f"{end_ns / 1e3:.3f}"])
    print(f"\nwrote {len(runs)} segments to {path}"
          f" ({dropped_disc} dropped for spanning a counter jump)")


def write_trace_meta(runs, dropped_disc, path):
    """Sidecar describing what the CSV's numbers can and cannot support.

    A consumer naturally divides total task time by
    `last.end_us - first.start_us` to get occupancy. On THIS lane that
    denominator is not elapsed time: CNTVCT advances while the core is in
    WFI at a rate unrelated to the tick clock, so the span includes idle
    stretches that never took that long.

    How wrong it gets depends on how idle the capture is, and the busy case
    is the dangerous one. An idle run inflates the span by orders of
    magnitude and the result is obviously absurd. The loaded TAP capture
    inflates it by only 1.3x -- 84063 ms against 65284 ms of busy time --
    and yields percentages that look entirely reasonable and are wrong.

    Rather than emit a CSV that silently produces a wrong percentage, state
    the limitation where a tool can read it. A busy span over non-idle
    segments IS meaningful and is supplied for anything that wants a
    denominator.
    """
    import json as _json
    busy = sum(e - s for s, e, lab in runs if not lab.startswith("idle"))
    meta = {
        "lane": LANE,
        "source": "CTF via scripts/parse-zephyr-ctf.py",
        # Without this, identifying which capture produced a given CSV meant
        # re-running the decoder over every candidate until the segment
        # counts matched.
        "source_path": SOURCE_PATH,
        "time_base_is_wall_clock": WALL_CLOCK_VALID,
        "wall_clock_span_valid": WALL_CLOCK_VALID,
        "busy_span_us": busy / 1e3,
        "busy_span_note":
            "Sum of non-idle execution segments."
            + ("" if WALL_CLOCK_VALID else
               " Use this as a denominator instead of the first..last span."),
        "segments": len(runs),
        "segments_dropped_counter_jump": dropped_disc,
        # Machine-readable so a consumer can decide per gap rather than
        # trusting or discarding the whole capture.
        "wrap_period_us": WRAP_PERIOD_NS / 1e3,
        "wrap_ambiguous_gaps": WRAP_GAPS,
        "heartbeat_corrections": HEARTBEAT_FIXES,
        "nonmonotonic_policy": "drop" if not WALL_CLOCK_VALID else "none",
    }
    if not WALL_CLOCK_VALID:
        meta["wall_clock_span_invalid_reason"] = (
            "CNTVCT advances during WFI at a rate unrelated to the tick "
            "clock, so first..last spans idle and is not elapsed time. Do "
            "not derive occupancy from it.")
    with open(path, "w") as fh:
        _json.dump(meta, fh, indent=2)
        fh.write("\n")
    print(f"wrote {path} "
          + ("(wall-clock span usable: target counter is elapsed time)"
             if WALL_CLOCK_VALID
             else "(wall-clock span marked INVALID for this lane)"))


def load_contract(path, launch):
    """Declared scheduling parameters, for the W3 conformance check.

    Deliberately a few regexes rather than a TOML parser: this reads two
    values out of two files and must not acquire a dependency to do it.
    """
    import re
    out = {}
    txt = open(path, encoding="utf-8").read()
    m = re.search(r"\[tiers\.[a-z_]+\.zephyr\](.*?)(?=\n\[|\Z)", txt, re.S)
    if m:
        pm = re.search(r"^\s*priority\s*=\s*(-?\d+)", m.group(1), re.M)
        if pm:
            out["tier_priority"] = int(pm.group(1))
    if launch:
        lt = open(launch, encoding="utf-8").read()
        lm = re.search(r'name="ctrl_period"\s+value="([0-9.]+)"', lt)
        if lm:
            out["ctrl_period_us"] = int(round(float(lm.group(1)) * 1e6))
    return out


def report_stats(evs):
    """Per-thread scheduling statistics reconstructed from switch events."""
    running = defaultdict(float)   # label -> total ns on CPU
    longest = defaultdict(float)   # label -> longest contiguous slice
    windows = defaultdict(int)     # label -> dispatch count
    counts = defaultdict(int)      # event name -> occurrences

    runs = []                      # (start_ns, end_ns, label) CPU intervals
    current = None
    since = None
    spanned = False        # did a WFI discontinuity fall inside this slice?
    dropped = 0
    for ev in evs:
        counts[ev.name] += 1
        if ev.disc:
            spanned = True
        if ev.name == "thread_switched_in":
            current, since, spanned = thread_label(ev), ev.ts, False
            windows[current] += 1
        elif ev.name == "thread_switched_out" and current is not None:
            slice_ns = ev.ts - since
            if spanned:
                dropped += 1          # gap is unmeasurable, not zero
            elif slice_ns >= 0:
                running[current] += slice_ns
                longest[current] = max(longest[current], slice_ns)
                # phase-9 W1/W2 — keep the interval itself, not just its sum.
                # A callback span is WALL time; subtracting the intervals in
                # which its thread was not running turns it into execution
                # time, which is what a budget is expressed in.
                runs.append((since, ev.ts, current))
            current, since, spanned = None, None, False

    if CSV_OUT:
        import os as _os
        write_segments_csv(runs, dropped, CSV_OUT)
        write_trace_meta(runs, dropped,
                         _os.path.join(_os.path.dirname(_os.path.abspath(CSV_OUT))
                                       or ".", "trace_meta.json"))

    # There is no trustworthy wall-clock span on this model: CNTVCT keeps
    # advancing while the core is in WFI, at a rate unrelated to the tick clock
    # the console prints. A 12.214 s loopback run accumulates ~2350 s of
    # counter time, essentially all of it inside idle slices (mean ~338 ms
    # each). So the idle thread's figures and any total-elapsed or CPU-percent
    # derived from them are meaningless here.
    #
    # What IS consistent is the non-idle accounting: those slices are bounded
    # by real execution, and their durations agree across runs. Use the sum of
    # non-idle execution as the base and report no CPU percentage.
    busy = sum(v for k, v in running.items() if not k.startswith("idle"))

    if WALL_CLOCK_VALID:
        print(f"\n[time base] target counter declared to BE elapsed time "
              f"(--wall-clock-valid); no slices discarded.")
    else:
        print(f"\n[time base] {sum(1 for e in evs if e.disc)} WFI counter "
              f"jumps seen, {dropped} slices dropped for spanning one. No "
              f"wall-clock span is reported -- see rt_evaluation_zephyr.rst.")
    report_wrap_ambiguity(WRAP_GAPS)

    print("\n=== event counts " + "=" * 47)
    for name, c in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {name:<34} {c:>8}")

    print("\n=== per-thread scheduling " + "=" * 38)
    print(f"  non-idle execution: {busy / 1e6:.3f} ms over {len(evs)} events")
    print("  idle rows are shown for completeness but their times are NOT")
    print("  meaningful on this model (CNTVCT advances during WFI).")
    print(f"  {'thread':<30} {'total ms':>10} "
          f"{'dispatches':>11} {'longest ms':>11} {'mean ms':>9}")
    for label, total in sorted(running.items(), key=lambda kv: -kv[1]):
        w = windows[label]
        mean = (total / w / 1e6) if w else 0.0
        note = "  <- idle, times not meaningful" if label.startswith("idle") else ""
        print(f"  {label:<30} {total / 1e6:>10.3f} "
              f"{w:>11} {longest[label] / 1e6:>11.3f} {mean:>9.4f}{note}")

    # phase-7 W6 — application markers. The CTF stream shows executor wakes,
    # not callback boundaries, because callbacks run inside a wake as ordinary
    # calls. `app_marker` (out-of-tree, patches/zephyr/0002) brackets the
    # control cycle so its PERIOD and DURATION are measurable, and so a cycle
    # can be read against the switches and ISRs that landed inside it.
    OUTCOME = {0: "commanded", 1: "safe_stop", 2: "not_ready"}
    ENTER, EXIT = 1, 2
    marks = [e for e in evs if e.name == "app_marker"]

    # Marker ids 1..7 are the hand-placed control-cycle markers
    # (common/diag/trace_marker.hpp); 16..19 are the phase-8 callback dispatch
    # hooks, reported in their own section below. Split them here so the two
    # never pair with each other: the duration walk below pairs an ENTER with
    # the NEXT marker of any other id, so an interleaved callback marker would
    # be read as a cycle exit and silently truncate every cycle.
    #
    # Discontinuity events are kept whatever their id -- both walks below test
    # `ev.disc` before the id, so carrying them through preserves exactly the
    # WFI handling that was here before.
    cycle_marks = [e for e in marks
                   if e.disc or 1 <= e.fields.get("marker_id", 0) <= 7]
    if any(1 <= e.fields.get("marker_id", 0) <= 7 for e in cycle_marks):
        print("\n=== control cycles (app markers) " + "=" * 31)
        enters = [e for e in cycle_marks if e.fields.get("marker_id") == ENTER]
        exits = [e for e in cycle_marks if e.fields.get("marker_id") == EXIT]
        print(f"  enter={len(enters)}  exit={len(exits)}")

        # Cycle PERIOD: enter-to-enter. This is the number the 30 ms
        # ctrl_period is actually a claim about.
        starts = [e.ts for e in enters if not e.disc]
        if len(starts) > 2:
            g = sorted((b - a) / 1e6 for a, b in zip(starts, starts[1:]) if b > a)
            print(f"  period ms:   min={g[0]:.3f} p50={g[len(g) // 2]:.3f} "
                  f"p90={g[int(len(g) * 0.9)]:.3f} p99={g[int(len(g) * 0.99)]:.3f} "
                  f"max={g[-1]:.3f}  n={len(g)}")

        # Cycle DURATION: enter to its own exit. Pair by walking the stream, so
        # an unmatched marker (a capture that starts or ends mid-cycle) is
        # dropped rather than silently pairing across cycles.
        durs, outcomes, pending = [], Counter(), None
        for ev in cycle_marks:
            if ev.disc:
                pending = None
                continue
            mid = ev.fields.get("marker_id")
            if mid == ENTER:
                pending = ev
            elif mid == EXIT and pending is not None:
                durs.append((ev.ts - pending.ts) / 1e6)
                outcomes[OUTCOME.get(ev.fields.get("arg"), ev.fields.get("arg"))] += 1
                pending = None
            # Any OTHER marker id is a PHASE boundary inside the cycle and must
            # be stepped over. Pairing ENTER with "the next marker of any id"
            # -- which this loop did until 2026-08-29 -- closed the cycle at the
            # first phase marker instead of at EXIT, so `duration` measured
            # ENTER->data_checked rather than the cycle. The tell was in the
            # output all along: n was 1143 against exit=1142, and you cannot
            # build 1143 enter->exit pairs out of 1142 exits.
        if durs:
            d = sorted(durs)
            print(f"  duration ms: min={d[0]:.3f} p50={d[len(d) // 2]:.3f} "
                  f"p90={d[int(len(d) * 0.9)]:.3f} p99={d[int(len(d) * 0.99)]:.3f} "
                  f"max={d[-1]:.3f}  n={len(d)}")
            print("  outcomes:    " + ", ".join(f"{k}={v}" for k, v in outcomes.most_common()))

        # phase-7 W7 — attribute the tail. The cycle markers say a callback ran
        # long; these say WHICH PART did. Phases are the spans between the
        # enter marker and the three in-cycle boundaries, so they only exist on
        # a cycle that got past the readiness checks (a safe_stop exits before
        # `inputs_done` and contributes nothing here).
        INPUTS, LAT, LON, CHECKED, COPIED = 3, 4, 5, 6, 7
        PHASES = [("in:process_data", ENTER, CHECKED),
                  ("in:copy_inputs", CHECKED, COPIED),
                  ("in:is_ready", COPIED, INPUTS),
                  ("inputs (total)", ENTER, INPUTS),
                  ("mpc_lateral", INPUTS, LAT),
                  ("pid_longitudinal", LAT, LON), ("publish", LON, EXIT)]
        seen, spans = {}, {name: [] for name, _, _ in PHASES}
        for ev in cycle_marks:
            mid = ev.fields.get("marker_id")
            if ev.disc:
                seen.clear()
                continue
            if mid == ENTER:
                seen = {ENTER: ev.ts}
            elif seen:
                for name, a, b in PHASES:
                    if mid == b and a in seen:
                        spans[name].append((ev.ts - seen[a]) / 1e6)
                seen[mid] = ev.ts
        if any(spans.values()):
            print("  phase breakdown (cycles that reached the controllers):")
            print(f"    {'phase':<18} {'p50 ms':>9} {'p90 ms':>10} {'max ms':>10} {'n':>7}")
            for name, _, _ in PHASES:
                v = sorted(spans[name])
                if not v:
                    continue
                print(f"    {name:<18} {v[len(v) // 2]:>9.3f} "
                      f"{v[int(len(v) * 0.9)]:>10.3f} {v[-1]:>10.3f} {len(v):>7}")

    # phase-8 W5 — per-callback statistics from the executor dispatch hooks.
    # Design: docs/design/callback_tracing.rst. The schema there is three
    # events -- nros_callback_register(handle, kind, name), callback_start(
    # handle), callback_end(handle) -- and this is where they are read back.
    #
    # ENCODING. Zephyr 3.7 has no user-event facility, so the transport is the
    # same out-of-tree `app_marker` event the phase-7 markers use, whose
    # payload is exactly two uint32 fields, (marker_id, arg). Three events with
    # a variable-length string have to fit through that. The scheme:
    #
    #   16  register   arg = handle << 8 | kind   (kind per CB_KINDS)
    #   17  name       arg = the next 4 name bytes, little-endian: byte i of
    #                  the chunk in bits 8*i. Repeat until the name is spent;
    #                  the final chunk is NUL-padded. Belongs to the register
    #                  event it FOLLOWS.
    #   18  start      arg = handle
    #   19  end        arg = handle
    #
    # Marker ids 1..7 are taken and must never be reused -- captured traces
    # carry them, and the header that defines them warns that renumbering
    # silently reinterprets every trace taken before it. The block starts at 16
    # rather than 8 so the phase markers keep room to grow contiguously.
    #
    # TRADE-OFF, stated honestly. Streaming the name positionally is the
    # simplest thing that works through a fixed two-word payload, and it costs
    # three things:
    #
    #   * The name is bound to the register event by ADJACENCY, not by handle.
    #     A dropped or interleaved event inside a registration burst
    #     mis-attributes a name. This is tolerable only because registration is
    #     init-time, once per callback, on one thread, before the traffic that
    #     is worth measuring -- and because a wrong NAME can never corrupt a
    #     DURATION, which is keyed on the handle in the runtime events alone.
    #   * A capture that starts after init has no registration events at all,
    #     so callbacks fall back to a `handle N` label. Numbers are unaffected.
    #   * The handle is 24 bits, not 32, because the kind shares the word.
    #
    # Rejected alternatives: widening the CTF event (needs a new Zephyr patch,
    # which phase-8 W4 exists specifically to avoid), and a compiled-in name
    # table keyed by handle (that is the hand-maintained registry this phase is
    # removing -- see the acceptance criteria).
    # 17 is the LEGACY untagged name chunk: 4 bytes, bound to the register
    # event it followed. 20 is the tagged form, `handle << 24 | 3 bytes`,
    # which binds by handle. Both are decoded — a new id was minted rather
    # than 17 redefined, so captures taken either way still read correctly.
    CB_REGISTER, CB_NAME_LEGACY, CB_START, CB_END, CB_NAME = 16, 17, 18, 19, 20
    CB_IDS = (CB_REGISTER, CB_NAME_LEGACY, CB_START, CB_END, CB_NAME)
    CB_KINDS = {0: "timer", 1: "subscription", 2: "service", 3: "action"}
    CB_NAME_MAX = 64   # bytes; longer names are truncated at the emitter

    if any(e.fields.get("marker_id") in CB_IDS for e in marks):
        # Walk the FULL stream, not just the app markers: a WFI counter jump
        # can land on any event, including one inside a callback, and a span
        # that contains one is unmeasurable rather than long.
        stream = [e for e in evs
                  if e.disc or (e.name == "app_marker"
                                and e.fields.get("marker_id") in CB_IDS)]

        kinds = {}                  # handle -> kind string; presence == registered
        names = {}                  # handle -> name, only when one was streamed
        durs = defaultdict(list)    # handle -> [ms] WALL time
        spans = defaultdict(list)   # handle -> [(start_ns, end_ns)]
        # Open spans are keyed by HANDLE rather than held in a single slot.
        # `app_marker` carries no thread id, and phase-8 W1 found dispatch
        # paths that run on a worker thread (`os_priority.rs`) as well as on
        # the executor's own, so two different callbacks can legitimately be
        # open at once and their markers interleave. A single slot would score
        # every one of those as unbalanced. Two dispatches of the SAME handle
        # overlapping is still treated as a lost end -- if the leaf hooks W1
        # settles on turn out to nest a handle inside itself, this needs to
        # become a stack per handle.
        chunks = {}                 # handle -> accumulated name bytes (W5a)
        legacy_open = None          # last register seen, for the legacy chunks
        collisions = {}             # handle -> [names] when one handle is reused
        pending = {}                # handle -> the open callback_start event
        crossed = set()             # handles whose open span met a WFI jump
        unbalanced = spanned = reordered = 0

        def finish_name(handle, raw):
            """Record a streamed name, or discard it if it is not printable.

            A garbled name is dropped rather than shown: the same stance the
            decoder already takes on thread names, and the handle still gets a
            `handle N` label so its numbers are not lost with it.
            """
            raw = bytes(raw).split(b"\x00", 1)[0]
            if not (raw and all(0x20 <= b <= 0x7E for b in raw)):
                return
            name = raw.decode("ascii")
            # phase-8 W3a — a handle is the executor's ENTRY SLOT INDEX, and
            # slot indices are unique within ONE executor, not across an image.
            # An image running several tier executors therefore emits colliding
            # handles, and every row below would silently merge two different
            # callbacks into one set of numbers -- the exact "looks like a
            # measurement" failure this instrumentation exists to remove.
            #
            # Nothing upstream detects it. Two registrations of one handle under
            # DIFFERENT names is the observable signature, so say so rather than
            # quietly keeping the last one.
            prev = names.get(handle)
            if prev is not None and prev != name:
                collisions.setdefault(handle, [prev]).append(name)
            names[handle] = name

        for ev in stream:
            if ev.disc:
                crossed |= set(pending)   # every open span straddles the jump
                if ev.name != "app_marker":
                    continue
            mid = ev.fields.get("marker_id")
            arg = ev.fields.get("arg", 0)

            if mid == CB_NAME_LEGACY:
                # Legacy: no handle in the payload, so it binds to the last
                # register event seen. Retained only to read old captures.
                if legacy_open is not None:
                    buf = chunks.setdefault(legacy_open, bytearray())
                    if len(buf) < CB_NAME_MAX:
                        buf += struct.pack("<I", arg)
                continue

            if mid == CB_NAME:
                # phase-8 W5a — the chunk carries its own handle in the top
                # byte, so a name binds to the callback it NAMES rather than to
                # whichever register event it happened to follow. A dropped
                # event inside a registration burst used to shift every
                # subsequent name onto the wrong callback, silently.
                h = (arg >> 24) & 0xFF
                buf = chunks.setdefault(h, bytearray())
                if len(buf) < CB_NAME_MAX:
                    buf += struct.pack("<I", arg & 0x00FF_FFFF)[:3]
                continue

            if mid == CB_REGISTER:
                # Register carries handle + kind only. The NAME arrives in
                # self-describing chunks (W5a) and is resolved after the
                # stream, so this no longer has to stay "open".
                h = arg >> 8
                # A SECOND register for a handle already carrying name bytes
                # means the slot is being reused -- finalise what we have so
                # the collision guard (W3a) sees two distinct names rather than
                # one concatenated buffer. Without this the legacy path
                # appends, `finish_name` truncates at the first NUL, and the
                # collision becomes invisible.
                if h in chunks:
                    finish_name(h, chunks.pop(h))
                legacy_open = h          # only used by the legacy name path
                kinds[h] = CB_KINDS.get(arg & 0xFF, f"kind {arg & 0xFF}")
            elif mid == CB_START:
                # A second start for a handle that is still open means its end
                # was lost. The open span is not a measurement; drop it and
                # count it rather than pairing across two dispatches.
                if arg in pending:
                    unbalanced += 1
                pending[arg] = ev
                crossed.discard(arg)
            elif mid == CB_END:
                start = pending.pop(arg, None)
                spanned_here = arg in crossed
                crossed.discard(arg)
                if start is None:
                    unbalanced += 1     # end with no start open for this handle
                elif spanned_here:
                    spanned += 1        # gap is unmeasurable, not zero
                elif ev.ts < start.ts:
                    # The event header carries no CPU id, so on an SMP image a
                    # later event can arrive with an earlier timestamp. A
                    # negative span is that, not a fast callback; the
                    # per-thread accounting above discards them for the same
                    # reason.
                    reordered += 1
                else:
                    durs[arg].append((ev.ts - start.ts) / 1e6)
                    spans[arg].append((start.ts, ev.ts))   # phase-9 W1/W2
        # Resolve every accumulated name once, keyed by handle. Order in the
        # stream no longer matters, so a capture that starts or ends inside a
        # registration burst loses at most the names it never saw -- it cannot
        # attach one callback's name to another.
        for h, buf in sorted(chunks.items()):
            finish_name(h, buf)
        unbalanced += len(pending)       # capture ended mid-dispatch

        print("\n=== callbacks (dispatch hooks) " + "=" * 33)
        paired = sum(len(v) for v in durs.values())
        print(f"  {len(kinds)} callbacks registered, {paired} dispatches paired")
        print(f"  dropped: {unbalanced} unbalanced, {spanned} spanning a WFI "
              f"counter jump, {reordered} out of order")
        if not kinds:
            print("  no registration events in this capture -- the names below")
            print("  are handles; re-capture from boot to resolve them.")
        if collisions:
            # W3a. Loud, and above the table, because every affected row below
            # is the SUM of two unrelated callbacks rather than a measurement.
            print("  !! HANDLE COLLISION -- these rows merge distinct callbacks:")
            for handle, seen in sorted(collisions.items()):
                print(f"       handle {handle}: " + " / ".join(seen))
            print("     A handle is an executor slot index, unique within ONE")
            print("     executor. Several executors in one image reuse indices,")
            print("     so the numbers for these handles are meaningless. Give")
            print("     each executor its own id before trusting them.")
        print(f"  {'callback':<26} {'kind':<12} {'n':>7} {'total ms':>10} "
              f"{'p50 ms':>9} {'p90 ms':>9} {'max ms':>10}")
        # Registered callbacks with no observed dispatch are listed too, and
        # the note printed after the table says why they are AMBIGUOUS rather
        # than letting a reader take n=0 for "never ran".
        for h in sorted(set(kinds) | set(durs), key=lambda h: -sum(durs[h])):
            v = sorted(durs[h])
            label = names.get(h, f"handle {h}")
            kind = kinds.get(h, "unregistered")
            if not v:
                print(f"  {label:<26} {kind:<12} {0:>7} "
                      f"{'-':>10} {'-':>9} {'-':>9} {'-':>10}")
                continue
            print(f"  {label:<26} {kind:<12} {len(v):>7} {sum(v):>10.3f} "
                  f"{v[len(v) // 2]:>9.3f} {v[int(len(v) * 0.9)]:>9.3f} "
                  f"{v[-1]:>10.3f}")

        # ---- phase-9 W1/W2 — execution time and preemption ----------------
        #
        # Everything above is WALL time: enter to exit, including any interval
        # in which the thread was not on a CPU. `TierSpec::budget_us` is an
        # EXECUTION-time budget, so the two have to be separated before any
        # number here can be fed back into the contract.
        #
        # Ownership is inferred, because app markers carry no thread id: the
        # owner of a span is whichever thread was running when the span opened.
        # That is exact for a callback, which cannot begin on a thread other
        # than the one dispatching it.
        if spans and runs:
            runs.sort()
            starts = [r[0] for r in runs]

            def slice_span(a, b):
                """Return (exec_ns, {preemptor: ns}) for the wall span [a, b)."""
                i = bisect.bisect_right(starts, a) - 1
                if i < 0:
                    i = 0
                owner = None
                for s0, e0, lab in runs[i:]:
                    if s0 <= a < e0:
                        owner = lab
                        break
                    if s0 >= b:
                        break
                if owner is None:
                    return None, None
                ex, stolen = 0, defaultdict(int)
                for s0, e0, lab in runs[i:]:
                    if s0 >= b:
                        break
                    ov = min(e0, b) - max(s0, a)
                    if ov <= 0:
                        continue
                    if lab == owner:
                        ex += ov
                    else:
                        stolen[lab] += ov
                return ex, stolen

            rows = []
            for h, sp in spans.items():
                execs, wall, steal = [], [], defaultdict(int)
                for a, b in sp:
                    ex, st = slice_span(a, b)
                    if ex is None:
                        continue
                    execs.append(ex / 1e6)
                    wall.append((b - a) / 1e6)
                    for k, v in st.items():
                        steal[k] += v
                if execs:
                    rows.append((h, sorted(execs), sorted(wall), steal))

            if rows:
                print("\n=== execution time vs wall time (phase-9 W1/W2) " + "=" * 16)
                print("  wall = enter..exit. exec = wall minus intervals the")
                print("  owning thread was off CPU. A budget is an EXEC figure;")
                print("  a deadline is measured against WALL.")
                print(f"  {'callback':<26} {'n':>6} {'wall p50':>9} {'wall max':>9} "
                      f"{'exec p50':>9} {'exec max':>9} {'preempted':>10}")
                for h, ex, wa, steal in sorted(rows, key=lambda r: -r[1][-1]):
                    label = names.get(h, f"handle {h}")
                    tot = sum(steal.values()) / 1e6
                    print(f"  {label:<26} {len(ex):>6} "
                          f"{wa[len(wa)//2]:>9.3f} {wa[-1]:>9.3f} "
                          f"{ex[len(ex)//2]:>9.3f} {ex[-1]:>9.3f} "
                          f"{tot:>10.3f}")
                any_steal = False
                for h, ex, wa, steal in rows:
                    if not steal:
                        continue
                    any_steal = True
                    label = names.get(h, f"handle {h}")
                    top = sorted(steal.items(), key=lambda kv: -kv[1])[:3]
                    who = ", ".join(f"{k} {v/1e6:.3f} ms" for k, v in top)
                    print(f"    {label}: preempted by {who}")
                if not any_steal:
                    print("    no preemption observed: every span ran to")
                    print("    completion on its owning thread.")

        # ---- phase-9 W3/W4 — conformance and budget extraction -------------
        if CONTRACT:
            print("\n=== schedule conformance (phase-9 W3) " + "=" * 25)
            obs_prio = {}
            for ev in evs:
                if ev.name == "thread_priority_set":
                    obs_prio[thread_label(ev)] = ev.fields.get("prio")
            ok = bad = 0

            def check(what, declared, observed, note=""):
                nonlocal ok, bad
                if observed is None:
                    print(f"  ?  {what:<34} declared {declared}, NOT OBSERVED {note}")
                    return
                if str(declared) == str(observed):
                    print(f"  OK {what:<34} {declared}")
                    ok += 1
                else:
                    print(f"  !! {what:<34} declared {declared}, observed {observed} {note}")
                    bad += 1

            # The boot tier runs on the CALLING thread rather than a spawned
            # one (nano-ros entry_tiers.rs), so the tier's priority lands on
            # `main`. Comparing against a thread named after the tier would
            # always report NOT OBSERVED.
            main_prio = next((v for k, v in obs_prio.items()
                              if k.startswith("main")), None)
            if "tier_priority" in CONTRACT:
                check("tier priority (Zephyr, on main)",
                      CONTRACT["tier_priority"], main_prio)
            if "ctrl_period_us" in CONTRACT:
                tp = None
                for h, sp in spans.items():
                    if (names.get(h, "") or "").startswith("timer@"):
                        st = sorted(a for a, _ in sp)
                        g = sorted(b - a for a, b in zip(st, st[1:]) if b > a)
                        if g:
                            tp = round(g[len(g) // 2] / 1e3)
                check("control period (us)", CONTRACT["ctrl_period_us"], tp,
                      "(median dispatch gap)")
            print(f"  {ok} conforming, {bad} divergent")

            print("\n=== suggested contract values (phase-9 W4) " + "=" * 20)
            print("  OBSERVED MAXIMA, not WCET, and FVP times are not silicon.")
            print("  Basis: budget_us = exec max, deadline_us = wall max.")
            for h, ex, wa, _ in sorted(rows, key=lambda r: -r[1][-1]):
                label = names.get(h, f"handle {h}")
                print(f"  {label:<34} budget_us = {int(ex[-1]*1000):>9}  "
                      f"deadline_us = {int(wa[-1]*1000):>9}")

        silent = sorted(h for h in kinds if not durs.get(h))
        if silent:
            # phase-8: leaf hooks are STAGED. Only the timer and the C-FFI
            # subscription path emit start/end today; 30 of the 33 leaf sites
            # in arena.rs carry a TODO instead. So an empty row has two
            # possible causes and the trace cannot tell them apart:
            #
            #   the callback genuinely never fired, or
            #   it fired and its leaf has no hook yet.
            #
            # Printing n=0 without saying this would let a reader conclude
            # "that callback never ran", which may be flatly untrue -- the
            # exact false-confidence this instrumentation exists to remove.
            print()
            print(f"  {len(silent)} registered callback(s) produced no dispatch"
                  " events:")
            for h in silent:
                print(f"       {names.get(h, f'handle {h}')} "
                      f"({kinds.get(h, '?')})")
            print("     AMBIGUOUS: either they never fired, or their leaf is")
            print("     one of the un-hooked sites (phase-8 staged 30 of 33).")
            print("     The trace cannot distinguish these two.")

    # Timers: `timer_start` carries the REQUESTED duration/period in ticks
    # alongside the arm time, so the requested period and the delivered
    # interval can be compared without inferring either. That pair is the
    # discriminator for nano-ros 0746 -- a wrong `period` means the timeout is
    # armed short, a right `period` with a short interval means the executor
    # is dispatching more often than the kernel fires.
    starts = [ev for ev in evs if ev.name == "timer_start"]
    if starts:
        print("\n=== timers " + "=" * 53)
        by_timer = defaultdict(list)
        for ev in starts:
            by_timer[ev.fields.get("id")].append(ev)
        for tid, arms in sorted(by_timer.items(), key=lambda kv: -len(kv[1])):
            req = {(a.fields.get("duration"), a.fields.get("period")) for a in arms}
            req_s = ", ".join(f"duration={d} period={p} ticks" for d, p in sorted(req))
            print(f"  timer {tid}: {len(arms)} arms   requested: {req_s}")
            if len(arms) > 2:
                gaps = sorted((b.ts - a.ts) / 1e6 for a, b in zip(arms, arms[1:]))
                print(f"    arm-to-arm ms: min={gaps[0]:.3f} "
                      f"p50={gaps[len(gaps) // 2]:.3f} "
                      f"p95={gaps[int(len(gaps) * 0.95)]:.3f} "
                      f"max={gaps[-1]:.3f} "
                      f"mean={sum(gaps) / len(gaps):.3f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", help="raw CTF stream captured from the target")
    ap.add_argument("-m", "--metadata",
                    default="zephyr/subsys/tracing/ctf/tsdl/metadata",
                    help="TSDL metadata (default: the pinned zephyr tree's)")
    ap.add_argument("--contract", metavar="SYSTEM_TOML",
                    help="declared scheduling parameters to check the trace "
                         "against (phase-9 W3); pair with --launch")
    ap.add_argument("--launch", metavar="LAUNCH_XML",
                    help="launch file supplying ctrl_period for --contract")
    ap.add_argument("--csv", metavar="TRACE_CSV",
                    help="write task,start_us,end_us execution segments (the "
                         "shape nano-ros-rt-eval's FreeRTOS lane emits), plus "
                         "a trace_meta.json describing this lane's time base")
    ap.add_argument("--wall-clock-valid", action="store_true",
                    help="the target's counter IS elapsed time (real "
                         "silicon). Default assumes the Arm FVP, whose "
                         "counter races ahead across WFI, and which needs "
                         "idle-spanning slices discarded. Setting this on an "
                         "FVP capture, or omitting it on hardware, produces "
                         "confidently wrong occupancy either way.")
    ap.add_argument("--heartbeat", metavar="ID:PERIOD_US",
                    help="resolve wrap ambiguity from a periodic app_marker "
                         "whose `arg` is a monotonic sequence counter, e.g. "
                         "--heartbeat 8:1000000 for marker id 8 every 1 s. "
                         "Without one, a gap longer than 4.295 s is "
                         "unrecoverable and the decoder silently assumes the "
                         "shortest reading.")
    ap.add_argument("--lane", default="zephyr-fvp",
                    help="target label recorded in trace_meta.json, e.g. "
                         "zephyr-mr-canhubk3. Default: zephyr-fvp")
    ap.add_argument("--timeline", action="store_true", help="print every event")
    ap.add_argument("--stats", action="store_true", help="print scheduling statistics")
    ap.add_argument("--limit", type=int, default=0,
                    help="with --timeline, stop after N events")
    args = ap.parse_args()

    if not (args.timeline or args.stats):
        args.stats = True

    events = parse_metadata(args.metadata)
    blob = open(args.trace, "rb").read()

    # BEFORE decode(): it reads WALL_CLOCK_VALID to decide whether an
    # idle-spanning counter jump is an FVP artifact to discard or real
    # elapsed time to keep.
    global WALL_CLOCK_VALID, LANE, WRAP_GAPS, HEARTBEAT_FIXES
    WALL_CLOCK_VALID = args.wall_clock_valid
    LANE = args.lane

    evs, health = decode(blob, events)

    # Reconstruction has to happen before anything reads a timestamp.
    if args.heartbeat and evs:
        try:
            hb_id, hb_us = args.heartbeat.split(":")
            hb_id, hb_us = int(hb_id), float(hb_us)
        except ValueError:
            print(f"--heartbeat wants ID:PERIOD_US, got {args.heartbeat!r}",
                  file=sys.stderr)
            return 1
        if hb_us * 1e3 >= WRAP_AMBIGUITY_WARN_NS:
            print(f"--heartbeat period {hb_us / 1e6:.3f} s is not under half "
                  f"the wrap period ({WRAP_AMBIGUITY_WARN_NS / 1e9:.3f} s); "
                  f"it cannot disambiguate anything.", file=sys.stderr)
            return 1
        HEARTBEAT_FIXES = reconstruct_epochs_from_heartbeat(
            evs, hb_id, hb_us * 1e3)
        recovered = sum(f["recovered_us"] for f in HEARTBEAT_FIXES)
        print(f"[heartbeat] marker {hb_id} @ {hb_us / 1e3:.3f} ms: "
              f"{len(HEARTBEAT_FIXES)} correction(s), "
              f"{recovered / 1e6:.3f} s of lost time recovered.")
    if evs:
        WRAP_GAPS = wrap_ambiguous_gaps(evs)

    print(f"metadata: {len(events)} event types    stream: {len(blob)} bytes")
    print(f"decoded:  {len(evs)} events    skipped: {health['skipped_bytes']} B"
          f"    trailing: {health['trailing_bytes']} B")
    if not evs:
        print("\nNo events decoded -- is this really a CTF stream?", file=sys.stderr)
        return 1

    if args.timeline:
        print("\n=== timeline " + "=" * 51)
        base = evs[0].ts
        for i, ev in enumerate(evs):
            if args.limit and i >= args.limit:
                print(f"  ... {len(evs) - args.limit} more events")
                break
            rel = (ev.ts - base) / 1e6
            fields = " ".join(f"{k}={v}" for k, v in ev.fields.items())
            print(f"  {rel:12.6f} ms  {ev.name:<28} {fields}")


    if args.csv:
        global CSV_OUT, SOURCE_PATH
        CSV_OUT = args.csv
        SOURCE_PATH = os.path.abspath(args.trace)
        args.stats = True
    if args.stats:
        if args.contract:
            global CONTRACT
            CONTRACT = load_contract(args.contract, args.launch)
        report_stats(evs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
