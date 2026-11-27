#!/usr/bin/env python3
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
"""Minimal SNTP (RFC 4330) responder for the isolated demo tap network.

The Zephyr island has no RTC and no internet route on tap0; without a
wall-clock epoch it stamps control commands from 1970 and Autoware's
vehicle_cmd_gate rejects them as stale, so autonomous mode never actuates.
The tap images point knobs.sntp.server (controller_bringup/system.toml) at
this responder
(default 192.168.10.1:12123 — an unprivileged port, so no root needed).

    scripts/sntp-server.py [--bind 192.168.10.1] [--port 12123]
                           [--step-seconds S] [--step-after-seconds T]
                           [--step-after-answers N] [--step-file PATH]

Stepping (nano-ros issue 0758, the SNTP re-sync check): the served time is
the host's clock plus an offset that starts at 0 and becomes --step-seconds
(default 1000) once T seconds have passed since the first answer, once N
answers have gone out, or on SIGUSR1, whichever comes first. The step is
logged ("sntp-server: stepped ... at host time ..."), and --step-file gets
the offset in seconds once it applies, so a checker can read the server's
clock as the host clock plus that offset.
"""
import argparse
import signal
import socket
import struct
import time

NTP_EPOCH_OFFSET = 2208988800  # 1900-01-01 -> 1970-01-01


def ntp_ts(t: float) -> tuple[int, int]:
    sec = int(t) + NTP_EPOCH_OFFSET
    frac = int((t - int(t)) * (1 << 32))
    return sec & 0xFFFFFFFF, frac & 0xFFFFFFFF


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bind", default="192.168.10.1")
    ap.add_argument("--port", type=int, default=12123)
    ap.add_argument("--step-seconds", type=float, default=1000.0,
                    help="offset the served time takes when it steps (s)")
    ap.add_argument("--step-after-seconds", type=float, default=None,
                    help="step this long after the first answer (s)")
    ap.add_argument("--step-after-answers", type=int, default=None,
                    help="step once this many answers have gone out")
    ap.add_argument("--step-file", default=None,
                    help="write the offset (s) here once it applies")
    args = ap.parse_args()

    state = {"offset": 0.0, "first": None, "answers": 0}

    def step(reason: str) -> None:
        if state["offset"] != 0.0:
            return
        state["offset"] = args.step_seconds
        print(f"sntp-server: stepped {args.step_seconds:+.3f} s ({reason}) "
              f"at host time {time.time():.3f}", flush=True)
        if args.step_file:
            with open(args.step_file, "w", encoding="utf-8") as handle:
                handle.write(f"{args.step_seconds}\n")

    signal.signal(signal.SIGUSR1, lambda *_: step("SIGUSR1"))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.settimeout(0.5)
    print(f"sntp-server: listening on {args.bind}:{args.port}", flush=True)

    while True:
        if (args.step_after_seconds is not None and state["first"] is not None
                and time.monotonic() - state["first"] >= args.step_after_seconds):
            step(f"{args.step_after_seconds:g} s after the first answer")
        if (args.step_after_answers is not None
                and state["answers"] >= args.step_after_answers):
            step(f"after {args.step_after_answers} answers")
        try:
            data, addr = sock.recvfrom(512)
        except socket.timeout:
            continue
        except InterruptedError:
            continue
        if len(data) < 48:
            continue
        rx_sec, rx_frac = ntp_ts(time.time() + state["offset"])
        # Originate timestamp of the reply = client's transmit timestamp.
        orig = data[40:48]
        vn = (data[0] >> 3) & 0x7
        li_vn_mode = (vn << 3) | 4  # LI=0, client's version, mode 4 (server)
        tx_sec, tx_frac = ntp_ts(time.time() + state["offset"])
        resp = (
            struct.pack(
                "!BBBb3I",
                li_vn_mode,
                2,      # stratum
                data[2],  # poll (echoed)
                -20,    # precision
                0,      # root delay
                0,      # root dispersion
                0x4C4F434C,  # reference id "LOCL"
            )
            + struct.pack("!2I", tx_sec, tx_frac)  # reference timestamp
            + orig                                  # originate timestamp
            + struct.pack("!2I", rx_sec, rx_frac)  # receive timestamp
            + struct.pack("!2I", tx_sec, tx_frac)  # transmit timestamp
        )
        sock.sendto(resp, addr)
        if state["first"] is None:
            state["first"] = time.monotonic()
        state["answers"] += 1
        print(f"sntp-server: answered {addr[0]}:{addr[1]} at host time "
              f"{time.time():.3f}, offset {state['offset']:+.3f} s", flush=True)


if __name__ == "__main__":
    main()
