// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 5 W5 — ported off the polling shim onto `nros::ComponentNode`
// (typed member-callback subscriptions, executor dispatch). Validates the
// ROS2 <-> Zephyr message conversion for every controller input topic plus
// the round-trip control output.

#include <cstdlib>
#include <new>

#include <nros/component_node.hpp>
#include <nros/nros.hpp>

#include "common/clock/clock.hpp"
#include "common/logger/logger.hpp"
#include "autoware/autoware_msgs/messages.hpp"

using namespace common::logger;

class DdsTestSub : public nros::ComponentNode {
public:
  explicit DdsTestSub(nros::NodeHandle h)
  : nros::ComponentNode(h, "dds_test_sub")
  {
    create_timer<DdsTestSub, &DdsTestSub::on_timer>(500);

    NROS_SUBSCRIBE(SteeringReportMsg, on_steering_report,
                   "/vehicle/status/steering_status");
    NROS_SUBSCRIBE(TrajectoryMsg_Raw, on_trajectory,
                   "/planning/scenario_planning/trajectory");
    NROS_SUBSCRIBE(OdometryMsg, on_odometry,
                   "/localization/kinematic_state");
    NROS_SUBSCRIBE(AccelerationMsg, on_acceleration,
                   "/localization/acceleration");
    NROS_SUBSCRIBE(OperationModeStateMsg, on_operation_mode_state,
                   "/system/operation_mode/state");
    NROS_SUBSCRIBE(ControlMsg, on_control_cmd,
                   "/control/trajectory_follower/control_cmd");
  }

  void on_timer() { log_info("Callback timer\n"); }

  void on_steering_report(const SteeringReportMsg & msg)
  {
    log_info("\n------ STEERING REPORT ------\n");
    log_info("Timestamp: %f\n", Clock::toDouble(msg.stamp));
    log_info("-------------------------------\n");
  }

  void on_operation_mode_state(const OperationModeStateMsg & msg)
  {
    log_info("\n------ OPERATION MODE STATE ------\n");
    log_info("Timestamp: %f\n", Clock::toDouble(msg.stamp));
    log_info("-------------------------------\n");
  }

  void on_odometry(const OdometryMsg & msg)
  {
    log_info("\n------ ODOMETRY ------\n");
    log_info("Timestamp: %f\n", Clock::toDouble(msg.header.stamp));
    log_info("-------------------------------\n");
  }

  void on_acceleration(const AccelerationMsg & msg)
  {
    log_info("\n------ ACCELERATION ------\n");
    log_info("Timestamp: %f\n", Clock::toDouble(msg.header.stamp));
    log_info("-------------------------------\n");
  }

  void on_trajectory(const TrajectoryMsg_Raw & msg)
  {
    static int count = 0;
    TrajectoryMsg trajectory_msg(&msg);  // Raw DDS sequence -> vector
    log_success("\n------ TRAJECTORY --IDX: %d ------\n", count++);
    log_success("Timestamp: %f\n", Clock::toDouble(trajectory_msg.header.stamp));
    log_success("Trajectory size: %d\n", trajectory_msg.points.size());
    log_success("-------------------------------\n");
  }

  // Round-trip endpoint: the board's controller output. Receiving this closes
  // the loop (host inputs -> board MPC/PID -> control_cmd -> host).
  void on_control_cmd(const ControlMsg & msg)
  {
    static int count = 0;
    log_success("\n====== CONTROL CMD #%d (from board) ======\n", count++);
    log_success("Timestamp: %f\n", Clock::toDouble(msg.stamp));
    log_success("steering_tire_angle: %f rad\n", msg.lateral.steering_tire_angle);
    log_success("accel: %f m/s^2  velocity: %f m/s\n",
                msg.longitudinal.acceleration, msg.longitudinal.velocity);
    log_success("==========================================\n");
  }
};

alignas(DdsTestSub) static unsigned char g_node_buf[sizeof(DdsTestSub)];

int main(void)
{
  log_info("--------------------------------\n");
  log_info("Starting DDS subscriber\n");
  log_info("--------------------------------\n");
  log_info("Waiting for DHCP to get IP address...\n");
  sleep(CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX);

#if defined(CONFIG_ENABLE_SNTP) && CONFIG_ENABLE_SNTP
  if (Clock::init_clock_via_sntp() < 0) {
    log_error("Failed to set time using SNTP\n");
  } else {
    log_info("Time set using SNTP\n");
  }
#endif

  if (!nros::init().ok()) {
    log_error("nros::init failed\n");
    std::exit(1);
  }
  nros::NodeHandle handle(nros::global_handle());
  auto * node = new (g_node_buf) DdsTestSub(handle);
  if (!node->ok()) {
    log_error("Failed to create DDS subscriber node: %s (code=%d)\n",
              node->error_what(), node->error_code());
    std::exit(1);
  }

  log_info("--------------------------------\n");
  log_info("DDS subscriber started\n");
  log_info("--------------------------------\n");

  while (true) {
    (void)nros::spin_once(10);
  }

  return 0;
}
