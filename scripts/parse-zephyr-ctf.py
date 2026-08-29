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

import argparse
import re
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
            disc = last_name == "idle"
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


def report_stats(evs):
    """Per-thread scheduling statistics reconstructed from switch events."""
    running = defaultdict(float)   # label -> total ns on CPU
    longest = defaultdict(float)   # label -> longest contiguous slice
    windows = defaultdict(int)     # label -> dispatch count
    counts = defaultdict(int)      # event name -> occurrences

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
            current, since, spanned = None, None, False

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

    print(f"\n[time base] {sum(1 for e in evs if e.disc)} WFI counter jumps seen, "
          f"{dropped} slices dropped for spanning one. No wall-clock span is "
          f"reported -- see rt_evaluation_zephyr.rst.")

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
    CB_REGISTER, CB_NAME, CB_START, CB_END = 16, 17, 18, 19
    CB_IDS = (CB_REGISTER, CB_NAME, CB_START, CB_END)
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
        durs = defaultdict(list)    # handle -> [ms]
        naming, chars = None, bytearray()
        # Open spans are keyed by HANDLE rather than held in a single slot.
        # `app_marker` carries no thread id, and phase-8 W1 found dispatch
        # paths that run on a worker thread (`os_priority.rs`) as well as on
        # the executor's own, so two different callbacks can legitimately be
        # open at once and their markers interleave. A single slot would score
        # every one of those as unbalanced. Two dispatches of the SAME handle
        # overlapping is still treated as a lost end -- if the leaf hooks W1
        # settles on turn out to nest a handle inside itself, this needs to
        # become a stack per handle.
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
            if raw and all(0x20 <= b <= 0x7E for b in raw):
                names[handle] = raw.decode("ascii")

        for ev in stream:
            if ev.disc:
                crossed |= set(pending)   # every open span straddles the jump
                if ev.name != "app_marker":
                    continue
            mid = ev.fields.get("marker_id")
            arg = ev.fields.get("arg", 0)

            if mid == CB_NAME:
                if naming is not None and len(chars) < CB_NAME_MAX:
                    chars += struct.pack("<I", arg)
                continue
            if naming is not None:       # any other marker ends the name
                finish_name(naming, chars)
                naming, chars = None, bytearray()

            if mid == CB_REGISTER:
                naming, chars = arg >> 8, bytearray()
                kinds[naming] = CB_KINDS.get(arg & 0xFF, f"kind {arg & 0xFF}")
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
        if naming is not None:           # capture ended mid-registration
            finish_name(naming, chars)
        unbalanced += len(pending)       # capture ended mid-dispatch

        print("\n=== callbacks (dispatch hooks) " + "=" * 33)
        paired = sum(len(v) for v in durs.values())
        print(f"  {len(kinds)} callbacks registered, {paired} dispatches paired")
        print(f"  dropped: {unbalanced} unbalanced, {spanned} spanning a WFI "
              f"counter jump, {reordered} out of order")
        if not kinds:
            print("  no registration events in this capture -- the names below")
            print("  are handles; re-capture from boot to resolve them.")
        print(f"  {'callback':<26} {'kind':<12} {'n':>7} {'total ms':>10} "
              f"{'p50 ms':>9} {'p90 ms':>9} {'max ms':>10}")
        # Registered-but-never-dispatched callbacks are listed too: "this one
        # never ran" is a finding, and dropping the row would hide it.
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
    ap.add_argument("--timeline", action="store_true", help="print every event")
    ap.add_argument("--stats", action="store_true", help="print scheduling statistics")
    ap.add_argument("--limit", type=int, default=0,
                    help="with --timeline, stop after N events")
    args = ap.parse_args()

    if not (args.timeline or args.stats):
        args.stats = True

    events = parse_metadata(args.metadata)
    blob = open(args.trace, "rb").read()
    evs, health = decode(blob, events)

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

    if args.stats:
        report_stats(evs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
