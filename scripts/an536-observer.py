#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""Observer for the issue-0836 probe: proves which DIRECTION works.

The island publishes a control command every cycle, including while it is
holding a safe stop. So if this host node receives those commands while the
island reports receiving nothing, the tap, the domain, multicast discovery and
the QoS match are all proven good and the failure is specifically host→island
DATA — which is a much narrower claim than "the trajectory does not arrive".

It also reports, per input topic, how many island subscriptions the host has
matched. A zero there would mean the readers were never discovered, and no
statement about delivery would be meaningful.
"""

import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy

from autoware_control_msgs.msg import Control
from autoware_planning_msgs.msg import Trajectory
from autoware_vehicle_msgs.msg import SteeringReport
from geometry_msgs.msg import AccelWithCovarianceStamped
from nav_msgs.msg import Odometry

TOPICS = [
    (Odometry, "/localization/kinematic_state"),
    (AccelWithCovarianceStamped, "/localization/acceleration"),
    (SteeringReport, "/vehicle/status/steering_status"),
    (Trajectory, "/planning/scenario_planning/trajectory"),
]


def main():
    rclpy.init()
    node = Node("asi_observer")
    qos = QoSProfile(
        depth=1,
        history=HistoryPolicy.KEEP_LAST,
        reliability=ReliabilityPolicy.RELIABLE,
        durability=DurabilityPolicy.VOLATILE,
    )

    count = {"n": 0}

    def on_cmd(_msg):
        count["n"] += 1

    node.create_subscription(Control, "/control/trajectory_follower/control_cmd",
                             on_cmd, qos)
    # Publishers only so get_subscription_count() can report whether the
    # island's readers were matched at all.
    probes = [(t, node.create_publisher(m, t, qos)) for m, t in TOPICS]

    end = time.time() + 25.0
    while time.time() < end and rclpy.ok():
        rclpy.spin_once(node, timeout_sec=0.1)

    print(f"island_control_cmds_received={count['n']}", flush=True)
    for topic, pub in probes:
        print(f"matched_island_readers {topic} = {pub.get_subscription_count()}",
              flush=True)


if __name__ == "__main__":
    main()
