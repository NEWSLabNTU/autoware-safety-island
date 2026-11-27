#!/usr/bin/env python3
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
"""Record the island's own output stamps against the host's receive time.

Subscribes to the island's /control/trajectory_follower/control_cmd
(autoware_control_msgs/Control; the island publishes it every control cycle,
HOLD included, so no input is needed) and writes one CSV row per sample:

    recv_host_s,stamp_s

recv_host_s is the host's clock (time.time()) when the sample arrived and
stamp_s is the message's `stamp`. The SNTP re-sync check
(actuation_module/test/run-fvp-tap-resync.sh, nano-ros issue 0758) turns the
pair into a stamp age against the SNTP server's clock afterwards.

    scripts/stamp-age-probe.py --out FILE [--seconds S] [--topic T]

Run it with ROS_DOMAIN_ID=2 (the island's domain) and a CYCLONEDDS_URI that
puts Cyclone on the island's network. Best-effort reader: it matches a
reliable or a best-effort writer.
"""

import argparse
import signal
import time

import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy

from autoware_control_msgs.msg import Control


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=300.0)
    ap.add_argument("--topic", default="/control/trajectory_follower/control_cmd")
    args = ap.parse_args()

    rclpy.init()
    node = Node("asi_stamp_age_probe")
    qos = QoSProfile(depth=10, history=HistoryPolicy.KEEP_LAST,
                     reliability=ReliabilityPolicy.BEST_EFFORT,
                     durability=DurabilityPolicy.VOLATILE)
    out = open(args.out, "w", encoding="utf-8", buffering=1)
    out.write("recv_host_s,stamp_s\n")
    count = {"n": 0}

    def on_cmd(msg: Control) -> None:
        now = time.time()
        out.write(f"{now:.6f},{msg.stamp.sec + msg.stamp.nanosec * 1e-9:.6f}\n")
        count["n"] += 1
        if count["n"] == 1:
            print(f"stamp-age-probe: first sample at host time {now:.3f}", flush=True)

    node.create_subscription(Control, args.topic, on_cmd, qos)
    print(f"stamp-age-probe: listening on {args.topic} for {args.seconds:g} s",
          flush=True)
    stop = {"now": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True))
    end = time.monotonic() + args.seconds
    try:
        while time.monotonic() < end and not stop["now"] and rclpy.ok():
            rclpy.spin_once(node, timeout_sec=0.2)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    print(f"stamp-age-probe: {count['n']} samples", flush=True)
    out.close()
    node.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()


if __name__ == "__main__":
    main()
