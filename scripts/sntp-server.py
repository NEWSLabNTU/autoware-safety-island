#!/usr/bin/env python3
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
"""Minimal SNTP (RFC 4330) responder for the isolated demo tap network.

The Zephyr island has no RTC and no internet route on tap0; without a
wall-clock epoch it stamps control commands from 1970 and Autoware's
vehicle_cmd_gate rejects them as stale, so autonomous mode never actuates.
The tap image points CONFIG_SNTP_SERVER_ADDRESS at this responder
(default 192.168.10.1:12123 — an unprivileged port, so no root needed).

    scripts/sntp-server.py [--bind 192.168.10.1] [--port 12123]
"""
import argparse
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
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    print(f"sntp-server: listening on {args.bind}:{args.port}", flush=True)

    while True:
        data, addr = sock.recvfrom(512)
        if len(data) < 48:
            continue
        rx_sec, rx_frac = ntp_ts(time.time())
        # Originate timestamp of the reply = client's transmit timestamp.
        orig = data[40:48]
        vn = (data[0] >> 3) & 0x7
        li_vn_mode = (vn << 3) | 4  # LI=0, client's version, mode 4 (server)
        tx_sec, tx_frac = ntp_ts(time.time())
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
        print(f"sntp-server: answered {addr[0]}:{addr[1]}", flush=True)


if __name__ == "__main__":
    main()
