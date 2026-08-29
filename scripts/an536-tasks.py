# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""GDB script: dump every FreeRTOS task on the an536 island and where it sits.

Run under gdb-multiarch attached to QEMU's stub:

    gdb-multiarch -q -batch -ex 'set arch arm' -ex 'file <elf>' \\
        -ex 'target remote :1234' -x scripts/an536-tasks.py

QEMU's gdb stub exposes CPUs, not FreeRTOS tasks, so `info threads` only ever
shows whichever task happens to be running. To answer "is Cyclone's receive
thread blocked, spinning, or gone" the task lists have to be walked by hand:
every task is on exactly one state list, and the list it is on IS its state.

For each non-running task the saved context is on its own stack, so the top of
that stack is scanned for values that resolve to code — the first few are where
the task will resume, i.e. where it is stuck.
"""

import gdb


def sym(addr):
    """Best-effort 'is this a code address' — returns a symbol name or None."""
    if addr < 0x10000000 or addr > 0x30000000:
        return None
    try:
        s = gdb.execute("info symbol 0x%x" % addr, to_string=True).strip()
    except gdb.error:
        return None
    if s.startswith("No symbol"):
        return None
    return s


def walk(list_expr, label, out):
    """Walk a FreeRTOS List_t and append (label, TCB) for each item."""
    try:
        lst = gdb.parse_and_eval(list_expr)
    except gdb.error:
        return
    try:
        n = int(lst["uxNumberOfItems"])
    except gdb.error:
        return
    if n == 0:
        return
    item = lst["xListEnd"]["pxNext"]
    for _ in range(n):
        if int(item) == 0:
            break
        try:
            tcb = item.dereference()["pvOwner"].cast(
                gdb.lookup_type("TCB_t").pointer())
            out.append((label, tcb))
            item = item.dereference()["pxNext"]
        except gdb.error:
            break


def main():
    tasks = []
    try:
        prios = int(gdb.parse_and_eval(
            "sizeof(pxReadyTasksLists)/sizeof(pxReadyTasksLists[0])"))
    except gdb.error:
        prios = 0
    for i in range(prios):
        walk("pxReadyTasksLists[%d]" % i, "READY(p%d)" % i, tasks)
    walk("*pxDelayedTaskList", "BLOCKED", tasks)
    walk("*pxOverflowDelayedTaskList", "BLOCKED-ovf", tasks)
    walk("xSuspendedTaskList", "SUSPENDED", tasks)
    walk("xTasksWaitingTermination", "DELETED", tasks)

    try:
        cur = int(gdb.parse_and_eval("pxCurrentTCB"))
    except gdb.error:
        cur = 0
    try:
        print("xTickCount = %d" % int(gdb.parse_and_eval("xTickCount")))
        print("uxCurrentNumberOfTasks = %d"
              % int(gdb.parse_and_eval("uxCurrentNumberOfTasks")))
    except gdb.error:
        pass
    print("tasks found = %d" % len(tasks))
    print()

    for state, tcb in tasks:
        try:
            name = tcb["pcTaskName"].string()
            prio = int(tcb["uxPriority"])
            top = int(tcb["pxTopOfStack"])
            base = int(tcb["pxStack"])
        except gdb.error:
            continue
        running = " <== RUNNING" if int(tcb) == cur else ""
        # TLS slot 0 is lwIP's per-thread netconn/select semaphore
        # (LWIP_NETCONN_SEM_PER_THREAD). A thread that calls lwip_select()
        # without having called sys_arch_netconn_sem_alloc() waits on a NULL
        # semaphore, so the signal that should wake it goes nowhere.
        try:
            tls = int(tcb["pvThreadLocalStoragePointers"][0])
        except gdb.error:
            tls = -1
        print("%-16s lwip_sem(TLS0)=%s" % ("", "NULL <-- !!" if tls == 0
                                           else "0x%08x" % tls))
        # Stack headroom: how close this task came to overflowing. A Cyclone
        # worker on a 1 KiB default stack is the failure this board has hit
        # before, so the number is worth printing even when nothing is wrong.
        print("%-16s prio=%-2d %-12s sp=0x%08x base=0x%08x used_below_sp=%d%s"
              % (name, prio, state, top, base, top - base, running))
        if int(tcb) == cur:
            print()
            continue
        seen = 0
        for off in range(0, 40):
            try:
                w = int(gdb.parse_and_eval(
                    "*(unsigned int *)0x%x" % (top + 4 * off)))
            except gdb.error:
                break
            s = sym(w)
            if s:
                print("      resume+%-3d %s" % (off, s))
                seen += 1
                if seen >= 4:
                    break
        print()


main()
