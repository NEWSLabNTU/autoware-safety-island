#!/usr/bin/env python3
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
"""Convert a Tonbandgeraet FreeRTOS trace to per-task execution segments.

Taken from NEWSLabNTU/nano-ros-rt-eval (tools/trace2csv.py). It is carried
here unchanged in substance so both lanes emit the same CSV that
scripts/analyze-trace-csv.py consumes; the Zephyr side of that contract is
`scripts/parse-zephyr-ctf.py --csv`. Only TBAND_CLI defaulting and the
trace_meta.json write are local.

Decodes `trace.bin` with `tband-cli dump` (JSON-lines of decoded events),
folds the TaskSwitchedIn stream into execution segments (single core: a
task executes from its switch-in until the next switch-in), and writes
`trace.csv` with rows `task,start_us,end_us`.

With `--pf` it also writes `trace.pf` (Perfetto) via `tband-cli conv`.
The mps2-an385 port's timestamp (tick count + SysTick down-counter) can
step backward a few us across a tick boundary; `conv` rejects such
streams, so the .pf path first rewrites the COBS frames with timestamps
clamped to be monotonic (the same clamp the CSV fold applies).

Task names come from the TaskName metadata events. Tasks sharing a name
(the two chained `nros_tier` tasks) are disambiguated by creation order —
task ids are minted sequentially at creation, so `nros_tier@1` is the
first-spawned (mid) tier and `nros_tier@2` the second (low).

Usage: python3 tools/trace2csv.py [--pf] results/freertos-trace/<ts>
       (argument may be the run dir or the trace.bin itself)
"""

import csv
import json
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# Vendored under the nano-ros submodule, same relative layout as the eval
# repo. Override with TBAND_CLI to use a build elsewhere.
TBAND_CLI = Path(
    os.environ.get(
        "TBAND_CLI",
        REPO
        / "modules/nros/third-party/tracing/Tonbandgeraet"
        / "tools/target/release/tband-cli",
    )
)

# Event ids whose frames carry no timestamp (metadata events); every other
# id encodes `id:u8 ts:varint ...`. From Tonbandgeraet tband_encode.h.
META_IDS = frozenset(
    [0x02, 0x03, 0x06, 0x0A, 0x5F, 0x60, 0x61, 0x64, 0x65, 0x7A, 0x7E]
)


def require_cli():
    if not TBAND_CLI.exists():
        sys.exit(
            f"tband-cli not found at {TBAND_CLI} -- build it with\n"
            "  cargo build --release -p tband-cli\n"
            "in modules/nros/third-party/tracing/Tonbandgeraet/tools "
            "(or set TBAND_CLI)."
        )


def dump_events(trace_bin):
    """Run `tband-cli dump` and yield decoded event dicts."""
    require_cli()
    proc = subprocess.run(
        [str(TBAND_CLI), "dump", "--format", "bin", "--mode", "free-rtos",
         str(trace_bin)],
        capture_output=True, text=True, check=True,
    )
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line:
            yield json.loads(line)


def segments(events):
    """Fold events into (task_label, start_us, end_us) execution segments."""
    names = {}          # task_id -> name from metadata
    switch_ins = []     # (ts, task_id), stream order
    ns_per_ts = None
    for evt in events:
        if "FreeRTOSMetadata" in evt:
            meta = evt["FreeRTOSMetadata"]
            if "TaskName" in meta:
                names[meta["TaskName"]["task_id"]] = meta["TaskName"]["name"]
        elif "BaseMetadata" in evt:
            meta = evt["BaseMetadata"]
            if "TsResolutionNs" in meta:
                ns_per_ts = meta["TsResolutionNs"]["ns_per_ts"]
        elif "FreeRTOS" in evt:
            kind = evt["FreeRTOS"]["kind"]
            if "TaskSwitchedIn" in kind:
                switch_ins.append(
                    (evt["FreeRTOS"]["ts"], kind["TaskSwitchedIn"]["task_id"])
                )
    if ns_per_ts is None:
        sys.exit("trace carries no TsResolutionNs metadata — cannot scale ts")
    if not switch_ins:
        sys.exit("trace carries no TaskSwitchedIn events")

    # The port timestamp can step back a few us across a tick boundary;
    # stream order is the true event order, so clamp monotonic.
    mono, last = [], 0
    for ts, tid in switch_ins:
        last = max(last, ts)
        mono.append((last, tid))

    # Disambiguate duplicate names by creation order (ids are sequential).
    by_name = defaultdict(list)
    for tid in sorted(names):
        by_name[names[tid]].append(tid)
    labels = {}
    for name, tids in by_name.items():
        if len(tids) == 1:
            labels[tids[0]] = name
        else:
            for i, tid in enumerate(tids, 1):
                labels[tid] = f"{name}@{i}"

    def label(tid):
        return labels.get(tid, f"task{tid}")

    def us(ts):
        return ts * ns_per_ts / 1000.0

    segs = []
    for (t0, tid), (t1, _) in zip(mono, mono[1:]):
        if t1 > t0:  # zero-length wedges add nothing
            segs.append((label(tid), us(t0), us(t1)))
    # The final switch-in has no successor: its end is unknown, drop it.
    return segs


# --- COBS-level monotonic rewrite (for tband-cli conv) ----------------------

def cobs_decode(frame):
    """Decode one COBS frame (delimiting zero already stripped)."""
    out = bytearray()
    i = 0
    while i < len(frame):
        code = frame[i]
        if code == 0:
            raise ValueError("zero code byte inside COBS frame")
        i += 1
        if i + code - 1 > len(frame):
            raise ValueError("COBS block past end of frame")
        out += frame[i:i + code - 1]
        i += code - 1
        if code != 0xFF and i < len(frame):
            out.append(0)
    return bytes(out)


def cobs_encode(data):
    """Encode to one COBS frame (no delimiting zero appended)."""
    out = bytearray()
    i = 0
    while True:
        end = min(i + 254, len(data))
        zero = data.find(0, i, end)
        if zero < 0:
            block = data[i:end]
            out.append(len(block) + 1)
            out += block
            i = end
            if i >= len(data):
                break
        else:
            block = data[i:zero]
            out.append(len(block) + 1)
            out += block
            i = zero + 1
            if i >= len(data):
                out.append(0x01)  # data ended with a zero
                break
    return bytes(out)


def read_varint(buf, i):
    val, shift = 0, 0
    while True:
        b = buf[i]
        val |= (b & 0x7F) << shift
        i += 1
        if not b & 0x80:
            return val, i
        shift += 7


def write_varint(val):
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def monotonic_bin(raw):
    """Rewrite a snapshot stream with timestamps clamped monotonic."""
    out = bytearray()
    last = 0
    for frame in raw.split(b"\x00"):
        if not frame:
            continue
        try:
            data = cobs_decode(frame)
        except ValueError:
            continue  # truncated trailing frame
        if data and data[0] not in META_IDS and len(data) > 1:
            try:
                ts, end = read_varint(data, 1)
            except IndexError:
                continue  # truncated event
            if ts < last:
                data = bytes([data[0]]) + write_varint(last) + data[end:]
            else:
                last = ts
        out += cobs_encode(data)
        out.append(0)
    return bytes(out)


def convert_pf(trace_bin):
    require_cli()
    raw = trace_bin.read_bytes()
    fixed = trace_bin.parent / "trace-mono.bin"
    fixed.write_bytes(monotonic_bin(raw))
    out = trace_bin.parent / "trace.pf"
    subprocess.run(
        [str(TBAND_CLI), "conv", "--format", "bin", "--mode", "free-rtos",
         "--core-count", "1", "--output", str(out), str(fixed)],
        check=True,
    )
    fixed.unlink()
    print(f"wrote {out}")


def main():
    args = [a for a in sys.argv[1:] if a != "--pf"]
    want_pf = "--pf" in sys.argv[1:]
    if not args:
        sys.exit("usage: trace2csv.py [--pf] <run-dir | trace.bin>")
    arg = Path(args[0])
    trace_bin = arg / "trace.bin" if arg.is_dir() else arg
    if not trace_bin.exists():
        sys.exit(f"no trace.bin at {trace_bin}")
    segs = segments(dump_events(trace_bin))

    out = trace_bin.parent / "trace.csv"
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["task", "start_us", "end_us"])
        for task, a, b in segs:
            w.writerow([task, f"{a:.3f}", f"{b:.3f}"])
    meta_path = trace_bin.parent / "trace_meta.json"
    meta = {}
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())
    meta.update({
        "lane": "freertos-mps2-an385",
        "source": "Tonbandgeraet snapshot via scripts/trace2csv-freertos.py",
        "source_path": str(trace_bin),
        # The fold gives task-to-task handover with no gaps, and the port
        # timestamp is a real tick counter, so first..last IS elapsed time.
        # (Contrast the Zephyr FVP lane, where it is not.)
        "wall_clock_span_valid": True,
        "segments": len(segs),
        "nonmonotonic_policy": "clamp",
    })
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")

    tasks = sorted({s[0] for s in segs})
    span = (segs[-1][2] - segs[0][1]) / 1e6
    print(f"wrote {out}: {len(segs)} segments, {span:.3f} s span")
    print(f"tasks: {', '.join(tasks)}")

    if want_pf:
        convert_pf(trace_bin)


if __name__ == "__main__":
    main()
