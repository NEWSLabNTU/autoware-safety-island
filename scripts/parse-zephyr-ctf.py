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
from collections import defaultdict

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
    """One decoded event: name, unwrapped timestamp (ns), and its fields."""

    __slots__ = ("name", "ts", "fields")

    def __init__(self, name, ts, fields):
        self.name = name
        self.ts = ts
        self.fields = fields

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

        if last_raw is not None and (last_raw - raw_ts) > WRAP_THRESHOLD_NS:
            epoch += 1 << 32
        last_raw = raw_ts

        out.append(Event(name, epoch + raw_ts, values))
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
    for ev in evs:
        counts[ev.name] += 1
        if ev.name == "thread_switched_in":
            current, since = thread_label(ev), ev.ts
            windows[current] += 1
        elif ev.name == "thread_switched_out" and current is not None:
            slice_ns = ev.ts - since
            if slice_ns >= 0:
                running[current] += slice_ns
                longest[current] = max(longest[current], slice_ns)
            current, since = None, None

    span = (evs[-1].ts - evs[0].ts) if len(evs) > 1 else 0

    # UNCALIBRATED CLOCK WARNING. On fvp_baser_aemv8r the reconstructed span
    # does not agree with the target's own console clock -- a DDS-loopback
    # capture whose console ran 12.214 s reconstructs as ~18300 s, a factor of
    # ~1330, and the discrepancy is NOT 32-bit wrap handling (summing only
    # forward deltas still gives ~16200 s). Until that is resolved, treat the
    # absolute microsecond/millisecond figures below as UNCALIBRATED: event
    # counts, orderings and per-thread structure are trustworthy, the times are
    # not. See docs/design/rt_evaluation_zephyr.rst.
    print("\n!! absolute times are UNCALIBRATED on fvp_baser_aemv8r "
          "(see rt_evaluation_zephyr.rst) -- counts and ordering are sound")

    print("\n=== event counts " + "=" * 47)
    for name, c in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {name:<34} {c:>8}")

    print("\n=== per-thread scheduling " + "=" * 38)
    print(f"  trace span: {span / 1e6:.3f} ms   events: {len(evs)}")
    print(f"  {'thread':<30} {'cpu %':>7} {'total ms':>10} "
          f"{'dispatches':>11} {'longest ms':>11} {'mean ms':>9}")
    for label, total in sorted(running.items(), key=lambda kv: -kv[1]):
        pct = (100.0 * total / span) if span else 0.0
        w = windows[label]
        mean = (total / w / 1e6) if w else 0.0
        print(f"  {label:<30} {pct:>6.2f}% {total / 1e6:>10.3f} "
              f"{w:>11} {longest[label] / 1e6:>11.3f} {mean:>9.4f}")

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
