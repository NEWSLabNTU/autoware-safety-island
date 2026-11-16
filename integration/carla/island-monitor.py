#!/usr/bin/env python3
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
"""Watch the ego's domain for island-check.sh; one JSON line per second.

Each line: wall time, the operation mode, the ego speed, and for the island's
bridged /control/trajectory_follower/control_cmd and the gate's
/control/command/control_cmd the samples that arrived in that second and the
largest |velocity| / |steering| among them. Every 5 s it also records whether
a node named controller_node_exe (Autoware's own follower) is on the graph.

It is also the run's operator. CARLA runs synchronously and swb pauses the
world between the stack's start and the scenario's, so the island's wall-clock
feedback watchdogs see the paused sources stop and latch SI_STOP before any
driving (steering report 0.5 s, odometry 0.4 s). While the ego is not in
AUTONOMOUS mode the monitor sends the island's operator re-enable
(/control/safety_island/reenable, on the island's domain) once a second; the
island clears the latch only when every source is fresh again. From the first
AUTONOMOUS second on it never re-enables, so a latch while driving stays and
fails the run. Each island log line about the latch or a re-enable is copied
into the record with the mode at that moment ("island" field).

  island-monitor.py <record.jsonl> <island.log> <island domain>
"""

import json
import sys
import threading
import time

import rclpy
import rclpy.executors
from autoware_adapi_v1_msgs.msg import OperationModeState
from autoware_control_msgs.msg import Control
from std_msgs.msg import Bool
from nav_msgs.msg import Odometry
from rclpy.qos import QoSDurabilityPolicy, QoSProfile, QoSReliabilityPolicy, qos_profile_sensor_data


def main():
    out = open(sys.argv[1], "a", buffering=1)
    island_log = open(sys.argv[2], "r", errors="replace")
    rclpy.init()
    node = rclpy.create_node("asi_island_monitor")
    # The island's domain: the operator's re-enable (a 1-byte Bool, inside the
    # 1400 B cap the island's domain carries).
    island_ctx = rclpy.Context()
    rclpy.init(context=island_ctx, domain_id=int(sys.argv[3]))
    operator = rclpy.create_node("asi_island_operator", context=island_ctx)
    reenable = operator.create_publisher(Bool, "/control/safety_island/reenable", 10)
    tick = {"follower": [], "gate": [], "island": []}
    state = {"mode": None, "autoware_control": None, "speed": None, "follower_node": None,
             "engaged": False}

    def on_cmd(key):
        def cb(msg):
            tick[key].append((abs(msg.longitudinal.velocity), abs(msg.lateral.steering_tire_angle)))
        return cb

    def on_mode(msg):
        state["mode"] = int(msg.mode)
        state["autoware_control"] = bool(msg.is_autoware_control_enabled)

    def on_odom(msg):
        state["speed"] = msg.twist.twist.linear.x

    node.create_subscription(Control, "/control/trajectory_follower/control_cmd",
                             on_cmd("follower"), qos_profile_sensor_data)
    node.create_subscription(Control, "/control/command/control_cmd",
                             on_cmd("gate"), qos_profile_sensor_data)
    # The island's own output, before the bridge (island_n): tells an island
    # that publishes slowly from a bridge that forwards slowly.
    operator.create_subscription(Control, "/control/trajectory_follower/control_cmd",
                                 on_cmd("island"), qos_profile_sensor_data)
    latched = QoSProfile(depth=1, reliability=QoSReliabilityPolicy.RELIABLE,
                         durability=QoSDurabilityPolicy.TRANSIENT_LOCAL)
    node.create_subscription(OperationModeState, "/api/operation_mode/state", on_mode, latched)
    node.create_subscription(Odometry, "/localization/kinematic_state", on_odom,
                             qos_profile_sensor_data)

    def report():
        if state["mode"] == 2:
            state["engaged"] = True
        events = [l.strip() for l in island_log.readlines()
                  if ("SI_STOP latched" in l or "re-enable" in l.lower() or "state changed" in l)
                  and "Operator re-enable requested" not in l]
        if not state["engaged"]:
            reenable.publish(Bool(data=True))
        line = {"t": round(time.time(), 3), **state, "island": events}
        for key, samples in tick.items():
            line[key + "_n"] = len(samples)
            line[key + "_vmax"] = round(max((s[0] for s in samples), default=0.0), 3)
            line[key + "_steer_max"] = round(max((s[1] for s in samples), default=0.0), 3)
            samples.clear()
        out.write(json.dumps(line) + "\n")

    def graph():
        state["follower_node"] = "controller_node_exe" in node.get_node_names()

    node.create_timer(1.0, report)
    node.create_timer(5.0, graph)
    executor = rclpy.executors.SingleThreadedExecutor()
    executor.add_node(node)
    island_executor = rclpy.executors.SingleThreadedExecutor(context=island_ctx)
    island_executor.add_node(operator)
    threading.Thread(target=island_executor.spin, daemon=True).start()
    try:
        executor.spin()
    except (KeyboardInterrupt, rclpy.executors.ExternalShutdownException):
        pass


if __name__ == "__main__":
    main()
