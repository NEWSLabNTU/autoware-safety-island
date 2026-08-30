#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright 2026 The Autoware Safety Island Authors
# SPDX-License-Identifier: Apache-2.0
"""Publisher for the issue-0836 size sweep.

Two modes, because the sweep needs both a variable and a control:

  --points N   publish a Trajectory with N points at 10 Hz. N is the knob: the
               serialized size grows ~88 bytes per point, so it walks the
               sample across the peer's 1400-byte MaxMessageSize and therefore
               across the RTPS fragment boundary.

  --small-only publish the topics the island demonstrably DOES receive. These
               run for the whole sweep so a dead link cannot be mistaken for a
               size cliff.

`ros2 topic pub` is not usable here: a 200-point Trajectory as CLI YAML is a
multi-kilobyte argv, and it gives no way to report the serialized size, which
is the number the sweep is actually indexed by.
"""

import argparse
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy
from rclpy.serialization import serialize_message

from autoware_planning_msgs.msg import Trajectory, TrajectoryPoint
from autoware_vehicle_msgs.msg import SteeringReport
from geometry_msgs.msg import AccelWithCovarianceStamped
from nav_msgs.msg import Odometry


def make_trajectory(n, stamp):
    """A geometrically plausible straight-line trajectory of n points.

    Content matters only in that the controller must not reject it as
    degenerate — a run of identical points would be discarded before it could
    tell us anything about delivery.
    """
    msg = Trajectory()
    msg.header.stamp = stamp
    msg.header.frame_id = "map"
    for i in range(n):
        p = TrajectoryPoint()
        p.time_from_start.sec = i // 10
        p.time_from_start.nanosec = (i % 10) * 100_000_000
        p.pose.position.x = 3714.44 + 0.5 * i
        p.pose.position.y = 73753.15 + 0.02 * i
        p.pose.orientation.z = 0.25
        p.pose.orientation.w = 0.968
        p.longitudinal_velocity_mps = 2.0
        msg.points.append(p)
    return msg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", type=int, default=0)
    ap.add_argument("--seconds", type=float, default=15.0)
    ap.add_argument("--small-only", action="store_true")
    ap.add_argument("--depth", type=int, default=1,
                    help="writer history depth. At 1 the writer keeps only "
                         "the newest sample, so one a reader is still "
                         "reassembling can vanish before repair finishes.")
    ap.add_argument("--traj-rate", type=float, default=0.1,
                    help="seconds between trajectory publishes")
    ap.add_argument("--with-trajectory", type=int, default=0,
                    help="also publish an N-point Trajectory at 10 Hz "
                         "from THIS node (one participant)")
    ap.add_argument("--rate", type=float, default=0.025,
                    help="seconds between small-topic publishes")
    ap.add_argument("--stagger", type=float, default=0.0,
                    help="seconds between create_publisher calls")
    args = ap.parse_args()

    rclpy.init()
    node = Node("asi_sweep_pub")

    # The island's readers are RELIABLE / KEEP_LAST(1) / VOLATILE (nano-ros
    # QoS::default_profile). A publisher that does not match is not a smaller
    # experiment, it is no experiment.
    qos = QoSProfile(
        depth=args.depth,
        history=HistoryPolicy.KEEP_LAST,
        reliability=ReliabilityPolicy.RELIABLE,
        durability=DurabilityPolicy.VOLATILE,
    )

    if args.small_only:
        # --stagger spaces the create_publisher calls out. Created back to
        # back, Cyclone packs their SEDP announcements into one datagram; with
        # a gap each announcement goes in its own. That packing is the variable
        # under test for issue 0836, so it has to be controllable.
        def gap():
            if args.stagger:
                time.sleep(args.stagger)

        p0 = node.create_publisher(Odometry, "/localization/kinematic_state", qos)
        gap()
        p1 = node.create_publisher(AccelWithCovarianceStamped,
                                   "/localization/acceleration", qos)
        gap()
        p2 = node.create_publisher(SteeringReport,
                                   "/vehicle/status/steering_status", qos)
        pubs = [
            (p0, Odometry()),
            (p1, AccelWithCovarianceStamped()),
            (p2, SteeringReport()),
        ]
        for _, m in pubs:
            if hasattr(m, "header"):
                m.header.frame_id = "map"
        # /system/operation_mode/state is deliberately NOT published: its
        # message package is not installed on this host, and processData()
        # reports every missing input independently, so its absence does not
        # gate the trajectory line this rig reads. It doubles as a negative
        # control — a topic nobody publishes must stay "Waiting".
        pubs[0][1].header.frame_id = "map"
        pubs[0][1].child_frame_id = "base_link"
        pubs[0][1].pose.pose.position.x = 3714.44
        pubs[0][1].pose.pose.position.y = 73753.15
        pubs[0][1].pose.pose.orientation.z = 0.25
        pubs[0][1].pose.pose.orientation.w = 0.968

        # Report match counts periodically. Whether the island's readers were
        # ever discovered is a precondition for any statement about delivery,
        # and it is the one number a publish-only loop otherwise never shows.
        traj_pub = None
        traj_msg = None
        traj_next = 0.0
        if args.with_trajectory > 0:
            traj_pub = node.create_publisher(
                Trajectory, "/planning/scenario_planning/trajectory", qos)
            traj_msg = make_trajectory(args.with_trajectory,
                                       node.get_clock().now().to_msg())
            print("trajectory points=%d serialized=%d"
                  % (args.with_trajectory, len(serialize_message(traj_msg))),
                  flush=True)

        names = ["kinematic_state", "acceleration", "steering_status"]
        next_report = 0.0
        while rclpy.ok():
            if traj_pub is not None and time.time() >= traj_next:
                traj_msg.header.stamp = node.get_clock().now().to_msg()
                traj_pub.publish(traj_msg)
                traj_next = time.time() + args.traj_rate
            if time.time() >= next_report:
                counts = " ".join(
                    "%s=%d" % (n, pub.get_subscription_count())
                    for n, (pub, _) in zip(names, pubs))
                print("matched " + counts, flush=True)
                next_report = time.time() + 5.0
            now = node.get_clock().now().to_msg()
            for pub, m in pubs:
                if hasattr(m, "header"):
                    m.header.stamp = now
                elif hasattr(m, "stamp"):
                    m.stamp = now
                pub.publish(m)
            time.sleep(args.rate)
        return

    pub = node.create_publisher(Trajectory, "/planning/scenario_planning/trajectory", qos)
    sample = make_trajectory(args.points, node.get_clock().now().to_msg())
    print(f"points={args.points} serialized={len(serialize_message(sample))}", flush=True)

    # Give discovery a moment; publishing into a graph the island has not yet
    # matched would lose samples for a reason that has nothing to do with size.
    deadline = time.time() + 3.0
    while time.time() < deadline and pub.get_subscription_count() == 0:
        time.sleep(0.1)
    print(f"matched_subscriptions={pub.get_subscription_count()}", flush=True)

    end = time.time() + args.seconds
    sent = 0
    while time.time() < end and rclpy.ok():
        sample.header.stamp = node.get_clock().now().to_msg()
        pub.publish(sample)
        sent += 1
        time.sleep(0.1)
    print(f"sent={sent}", flush=True)


if __name__ == "__main__":
    main()
