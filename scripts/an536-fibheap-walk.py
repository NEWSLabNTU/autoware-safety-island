# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""GDB script: walk a ddsrt fibheap sibling list and report whether it closes.

`ddsrt_fibheap_extract_min` walks the extracted node's children as a CIRCULAR
list:

    ddsrt_fibheap_node_t * const mark = min->children;
    ddsrt_fibheap_node_t *n = mark;
    do { n->parent = NULL; n->mark = 0; n = n->next; } while (n != mark);

so a `next` chain that never returns to `mark` spins forever, holding the event
queue lock. This walks the chain from a given node and answers three things:
does it close, does it close on a node OTHER than the start (a cycle that
excludes `mark` — the shape that hangs), or does it run off into unmapped
memory.

Usage:

    gdb-multiarch -q -batch -ex 'set arch arm' -ex 'file <elf>' \\
        -ex 'target remote :1234' \\
        -ex 'set $start = <addr>' -x scripts/an536-fibheap-walk.py
"""

import gdb

LIMIT = 64


def main():
    try:
        start = int(gdb.parse_and_eval("$start"))
    except gdb.error:
        print("set $start to the node address first")
        return
    node_t = gdb.lookup_type("ddsrt_fibheap_node_t").pointer()

    seen = {}
    n = start
    for i in range(LIMIT):
        if n == 0:
            print("  chain hit NULL after %d hops — not a circular list" % i)
            return
        if n in seen:
            print("  CYCLE: hop %d returns to hop %d (node %#x)" % (i, seen[n], n))
            if n == start:
                print("  ...and it closes on the START node, so this list is intact.")
            else:
                print("  ...and it does NOT include the start node %#x." % start)
                print("  That is the hang: the do/while compares against `mark`,")
                print("  which this cycle never reaches, so the loop never exits.")
            return
        seen[n] = i
        try:
            node = gdb.Value(n).cast(node_t)
            nxt = int(node["next"])
            prev = int(node["prev"])
            parent = int(node["parent"])
            children = int(node["children"])
        except gdb.error as exc:
            print("  hop %d: node %#x unreadable (%s) — chain leaves valid memory"
                  % (i, n, exc))
            return
        print("  %2d  node=%#x next=%#x prev=%#x parent=%#x children=%#x"
              % (i, n, nxt, prev, parent, children))
        n = nxt

    print("  no cycle within %d hops — list is longer than the limit or corrupt"
          % LIMIT)


main()
