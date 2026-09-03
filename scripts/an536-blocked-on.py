# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""GDB script: for every FreeRTOS task, report WHICH object it is waiting on.

`an536-tasks.py` answers "what state is each task in". When several tasks are
parked at once that is not enough: the question becomes whether they are waiting
on the SAME object (one stuck resource) or on different ones (independent
waits). FreeRTOS answers it directly — a blocked task's `xEventListItem` is
linked into the waiting-list of the queue/semaphore it blocked on, so

    container = pxTCB->xEventListItem.pvContainer

is the address of that list, and the queue it belongs to is that address minus
the list's offset within `Queue_t`. Tasks whose containers match are waiting on
one object.

`xStateListItem.pvContainer` says which state list holds the task; the suspended
list is where FreeRTOS puts an INDEFINITE wait (no timeout), which is the
distinction that matters when a thread was supposed to wake on a timer.

Run under gdb-multiarch attached to QEMU's stub:

    gdb-multiarch -q -batch -ex 'set arch arm' -ex 'file <elf>' \\
        -ex 'target remote :1234' -x scripts/an536-blocked-on.py
"""

import gdb


def addr_of(expr):
    try:
        return int(gdb.parse_and_eval("(unsigned long)&(%s)" % expr))
    except gdb.error:
        return 0


def sym(addr):
    if not addr:
        return "-"
    try:
        s = gdb.execute("info symbol 0x%x" % addr, to_string=True).strip()
    except gdb.error:
        return "0x%x" % addr
    if s.startswith("No symbol"):
        return "0x%x" % addr
    return s


def walk(list_expr, label, out):
    try:
        count = int(gdb.parse_and_eval("%s.uxNumberOfItems" % list_expr))
    except gdb.error:
        return
    if count == 0:
        return
    item = gdb.parse_and_eval("%s.xListEnd.pxNext" % list_expr)
    for _ in range(count):
        try:
            tcb = item["pvOwner"].cast(gdb.lookup_type("TCB_t").pointer())
            out.append((label, tcb))
            item = item["pxNext"]
        except gdb.error:
            return


def main():
    tasks = []
    try:
        n = int(gdb.parse_and_eval(
            "sizeof(pxReadyTasksLists)/sizeof(pxReadyTasksLists[0])"))
    except gdb.error:
        print("no FreeRTOS symbols — is this the right ELF?")
        return
    for i in range(n):
        walk("pxReadyTasksLists[%d]" % i, "READY(p%d)" % i, tasks)
    walk("xDelayedTaskList1", "DELAYED", tasks)
    walk("xDelayedTaskList2", "DELAYED2", tasks)
    walk("xSuspendedTaskList", "SUSPENDED", tasks)
    walk("xTasksWaitingTermination", "DYING", tasks)

    # Offset of xTasksWaitingToReceive / ToSend inside Queue_t, so a waiting
    # list address can be turned back into the queue that owns it.
    off_recv = off_send = None
    try:
        q = gdb.lookup_type("Queue_t")
        for f in q.fields():
            if f.name == "xTasksWaitingToReceive":
                off_recv = f.bitpos // 8
            elif f.name == "xTasksWaitingToSend":
                off_send = f.bitpos // 8
    except gdb.error:
        pass

    print("%-16s %-11s %-12s %s" % ("task", "state", "waiting-on", "detail"))
    seen = {}
    for state, tcb in tasks:
        try:
            name = tcb["pcTaskName"].string()
        except gdb.error:
            name = "?"
        try:
            container = int(tcb["xEventListItem"]["pvContainer"])
        except gdb.error:
            container = 0
        detail = "-"
        if container:
            if off_recv is not None and off_send is not None:
                qr = container - off_recv
                qs = container - off_send
                detail = "queue@0x%x (recv) | or 0x%x (send)" % (qr, qs)
            seen.setdefault(container, []).append(name)
        print("%-16s %-11s %-12s %s"
              % (name, state,
                 ("0x%x" % container) if container else "none", detail))

    print()
    shared = {c: ns for c, ns in seen.items() if len(ns) > 1}
    if shared:
        print("SHARED WAIT OBJECTS — these tasks are queued on one thing:")
        for c, ns in shared.items():
            print("  0x%x  <-  %s" % (c, ", ".join(ns)))
    else:
        print("No two tasks share a wait object: these are independent waits,")
        print("not a convoy behind a single stuck resource.")


main()
