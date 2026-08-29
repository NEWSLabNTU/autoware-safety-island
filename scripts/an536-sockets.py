# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""GDB script: lwIP socket/netconn state on the island.

Used for issue 0836 once the counters showed datagrams still arriving at the
UDP layer while the application received nothing. That narrows the loss to the
socket handoff, and this is where it becomes visible:

  * `recvmbox_queued` — datagrams sitting in the netconn mailbox, already
    delivered by lwIP and waiting for somebody to read them.
  * `rcvevent` — lwIP's readiness counter for select(). It is what
    `lwip_select` tests and what `event_callback` increments.

Data queued with `rcvevent` at zero is a lost wakeup: select() will sleep
forever on a socket that already holds data, and every later datagram is
dropped when the mailbox fills.
"""

import gdb


def main():
    try:
        n = int(gdb.parse_and_eval("sizeof(sockets)/sizeof(sockets[0])"))
    except gdb.error:
        print("no `sockets` symbol — is this an lwIP socket build?")
        return

    print("%-4s %-10s %-8s %-8s %-8s %-9s %s"
          % ("fd", "conn", "rcvevent", "sendevent", "errevent", "sel_wait",
             "recvmbox_queued"))
    for i in range(n):
        try:
            s = gdb.parse_and_eval("sockets[%d]" % i)
            conn = s["conn"]
            if int(conn) == 0:
                continue
            rcv = int(s["rcvevent"])
            snd = int(s["sendevent"])
            err = int(s["errevent"])
            try:
                selw = int(s["select_waiting"])
            except gdb.error:
                selw = -1
            # sys_mbox_t is `struct _sys_mbox { void *mbx; }` wrapping a
            # FreeRTOS QueueHandle_t; read uxMessagesWaiting out of the queue
            # rather than calling into the target, which a stopped remote
            # cannot do.
            queued = "?"
            try:
                q = int(conn.dereference()["recvmbox"]["mbx"])
                if q:
                    queued = int(gdb.parse_and_eval(
                        "((Queue_t *)0x%x)->uxMessagesWaiting" % q))
            except (gdb.error, gdb.MemoryError):
                pass
            flag = ""
            if queued not in ("?", 0) and rcv == 0:
                flag = "   <-- DATA QUEUED, rcvevent=0 (lost wakeup)"
            print("%-4d 0x%08x %-8d %-8d %-8d %-9d %s%s"
                  % (i, int(conn), rcv, snd, err, selw, queued, flag))
        except (gdb.error, gdb.MemoryError):
            continue


main()
