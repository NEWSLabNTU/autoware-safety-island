# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""GDB script: how fast is each topic actually reaching the controller?

The controller's log answers a boolean — "waiting for X" or silence — which
cannot separate "arriving at 10 Hz" from "arrived once, a minute ago". Every
freshness question is a rate question, so the rate has to be observable.

These counters live in the application callbacks, so they report what the
controller consumed, not what a layer below believes it delivered. That
distinction is what made the an536 receive-path work tractable: published at
40/40/40/10 Hz, the topics arrived at 10.7/8.2/10.6/**0.1** Hz, and only the
last of those was visible from the log (nano-ros issue 0917).

Build with `-DASI_RX_COUNTERS` (they compile to nothing otherwise), boot with
`-gdb tcp::1234`, then:

    gdb-multiarch -q -batch -ex 'set arch arm' -ex 'file <elf>' \\
        -ex 'target remote :1234' -x scripts/an536-rx-counters.py

Sample twice a known number of seconds apart to turn the totals into rates.

The reads are cast explicitly. The symbols are `volatile unsigned int` inside
an `extern "C"` block and gdb reports them as having no type, so a bare
`p asi_rx_traj` fails where `*(unsigned int *)&asi_rx_traj` works.

If every counter reads 0 while the island's log shows topics arriving, suspect
the CONNECTION rather than the guest: gdb falls back to the ELF's static
initialisers when `target remote` fails, and prints zeros without complaint.
Check for "Connection timed out" in gdb's output before believing a zero.
"""

import gdb

COUNTERS = (
    ("asi_rx_traj", "/planning/scenario_planning/trajectory"),
    ("asi_rx_odom", "/localization/kinematic_state"),
    ("asi_rx_accel", "/localization/acceleration"),
    ("asi_rx_steer", "/vehicle/status/steering_status"),
    ("asi_rx_opmode", "/system/operation_mode/state"),
)


def main():
    for name, topic in COUNTERS:
        try:
            value = int(gdb.parse_and_eval("*(unsigned int *)&" + name))
        except gdb.error as exc:
            print("%-14s : %s" % (name, exc))
            continue
        print("%-14s = %-8d %s" % (name, value, topic))


main()
