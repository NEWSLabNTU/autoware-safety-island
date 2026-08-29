# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""GDB script: print the island's lwIP counters and memp pool exhaustion.

Issue 0836 asks which half of the stack loses a packet. These counters answer
it directly: `link.recv` counts frames the driver handed up, `ip.recv` frames
that survived IP, `udp.recv` datagrams delivered to a PCB, and the `drop`/`err`
siblings say where the rest went. `memp` per-pool `err` counts are the other
half of the answer — an exhausted PBUF_POOL drops silently at the driver.

Requires LWIP_STATS=1 in lwipopts.h.
"""

import gdb

SECTIONS = ["link", "ip", "udp"]
FIELDS = ["xmit", "recv", "fw", "drop", "chkerr", "lenerr", "memerr",
          "rterr", "proterr", "opterr", "err", "cachehit"]


def main():
    try:
        st = gdb.parse_and_eval("lwip_stats")
    except gdb.error:
        print("lwip_stats not present — build with LWIP_STATS=1")
        return

    for name in SECTIONS:
        try:
            sec = st[name]
        except gdb.error:
            continue
        vals = []
        for f in FIELDS:
            try:
                v = int(sec[f])
            except gdb.error:
                continue
            if v:
                vals.append("%s=%d" % (f, v))
        print("%-6s %s" % (name, " ".join(vals) if vals else "(all zero)"))

    print()
    print("memp pools (used/max/avail, err = allocation failures):")
    try:
        n = int(gdb.parse_and_eval("sizeof(memp_pools)/sizeof(memp_pools[0])"))
    except gdb.error:
        n = 0
    for i in range(n):
        try:
            pool = gdb.parse_and_eval("memp_pools[%d]" % i)
            desc = pool["stats"]
            label = desc["name"].string()
            used = int(desc["used"])
            mx = int(desc["max"])
            avail = int(desc["avail"])
            err = int(desc["err"])
        except (gdb.error, gdb.MemoryError):
            continue
        flag = "   <-- EXHAUSTED" if err else ("   <-- AT LIMIT" if mx >= avail > 0 else "")
        print("  %-20s used=%-5d max=%-5d avail=%-5d err=%-5d%s"
              % (label, used, mx, avail, err, flag))


main()
