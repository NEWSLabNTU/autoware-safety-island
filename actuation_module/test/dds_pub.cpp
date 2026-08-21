// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 5 W5 — ported off the polling shim onto `nros::ComponentNode`.
// Publishes every controller input topic at 10 Hz so a host `dds_sub` /
// the controller image can validate the ROS2 <-> Zephyr conversion.

#include <chrono>
#include <cstdlib>
#include <new>

#include <nros/component_node.hpp>
#include <nros/nros.hpp>

#include "common/clock/clock.hpp"
#include "common/logger/logger.hpp"
#include "autoware/autoware_msgs/messages.hpp"

using namespace common::logger;

#define PUBLISH_PERIOD_MS (100)  // 10 Hz — realistic input cadence for the controller

class DdsTestPub : public nros::ComponentNode {
public:
  nros::Publisher<SteeringReportMsg> steering_pub;
  nros::Publisher<TrajectoryMsg_Raw> trajectory_pub;
  nros::Publisher<OdometryMsg> odometry_pub;
  nros::Publisher<AccelerationMsg> acceleration_pub;
  nros::Publisher<OperationModeStateMsg> operation_mode_pub;

  explicit DdsTestPub(nros::NodeHandle h)
  : nros::ComponentNode(h, "dds_test_pub")
  {
    steering_pub = create_publisher<SteeringReportMsg>(
      "/vehicle/status/steering_status");
    trajectory_pub = create_publisher<TrajectoryMsg_Raw>(
      "/planning/scenario_planning/trajectory");
    odometry_pub = create_publisher<OdometryMsg>(
      "/localization/kinematic_state");
    acceleration_pub = create_publisher<AccelerationMsg>(
      "/localization/acceleration");
    operation_mode_pub = create_publisher<OperationModeStateMsg>(
      "/system/operation_mode/state");
  }
};

alignas(DdsTestPub) static unsigned char g_node_buf[sizeof(DdsTestPub)];

// Pace the loop by spinning the executor for the full period — spin_once can
// return early on I/O activity, so budget on elapsed wall time, not call count.
static void spin_for_ms(long ms)
{
  const auto deadline =
    std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (std::chrono::steady_clock::now() < deadline) {
    (void)nros::spin_once(10);
  }
}

int main(void)
{
  log_info("--------------------------------\n");
  log_info("Starting DDS publisher\n");
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
  auto * node = new (g_node_buf) DdsTestPub(handle);
  if (!node->ok()) {
    log_error("Failed to create DDS publisher node: %s (code=%d)\n",
              node->error_what(), node->error_code());
    std::exit(1);
  }

  log_info("--------------------------------\n");
  log_info("DDS publisher started\n");
  log_info("--------------------------------\n");

  // idlc generated frame_id as char* historically; the generated C++ types
  // take these as string values, but keep the writable storage shape so the
  // test body stays identical across message-type generations.
  static char odom_frame_id[]      = "odom";
  static char base_link_frame_id[] = "base_link";

  while (true) {
    auto current_time = Clock::toRosTime(Clock::now());

    // Publish SteeringReport message. Value-initialize so any string members
    // start empty rather than as garbage.
    SteeringReportMsg steering_msg{};
    steering_msg.stamp = current_time;
    steering_msg.steering_tire_angle = 0.5;  // radians
    (void)node->steering_pub.publish(steering_msg);
    log_info("Published steering report: angle=%.2f\n",
             steering_msg.steering_tire_angle);

    // Publish Trajectory message: a straight path along +x starting near the
    // vehicle's odometry pose (x=10, y=20) at a constant 5 m/s, so the MPC has
    // a solvable path (>=3 points, identity orientation = yaw 0 facing +x,
    // time_from_start increasing). Keep the whole trajectory in ONE UDP
    // datagram (< CycloneDDS max_msg_size 1400 B): each TrajectoryPoint is
    // ~88 B, so 10 points (~920 B) avoids DDS fragmentation, which otherwise
    // congests the board's RX path and starves the small input topics.
    constexpr uint32_t TRAJ_POINTS = 10;
    constexpr double TRAJ_SPACING_M = 8.0;     // distance between points (80 m path)
    constexpr float  TRAJ_SPEED_MPS = 5.0f;    // matches published odometry vx
    TrajectoryMsg_Raw trajectory_msg{};
    trajectory_msg.header.stamp = current_time;
    trajectory_msg.header.frame_id = "map";
    for (uint32_t i = 0; i < TRAJ_POINTS; ++i) {
      TrajectoryPointMsg pt{};
      pt.pose.position.x = 10.0 + i * TRAJ_SPACING_M;
      pt.pose.position.y = 20.0;
      pt.pose.position.z = 0.0;
      pt.pose.orientation.x = 0.0;
      pt.pose.orientation.y = 0.0;
      pt.pose.orientation.z = 0.0;
      pt.pose.orientation.w = 1.0;           // identity: heading along +x
      pt.longitudinal_velocity_mps = TRAJ_SPEED_MPS;
      pt.lateral_velocity_mps = 0.0f;
      pt.acceleration_mps2 = 0.0f;
      const double t_s = (i * TRAJ_SPACING_M) / TRAJ_SPEED_MPS;
      pt.time_from_start.sec = (int32_t)t_s;
      pt.time_from_start.nanosec = (uint32_t)((t_s - (int32_t)t_s) * 1e9);
      (void)trajectory_msg.points.push_back(pt);
    }
    (void)node->trajectory_pub.publish(trajectory_msg);
    log_info("Published trajectory with %u points\n", TRAJ_POINTS);

    // Publish Odometry message (child_frame_id left empty via value-init)
    OdometryMsg odometry_msg{};
    odometry_msg.header.stamp = current_time;
    odometry_msg.header.frame_id = odom_frame_id;
    odometry_msg.pose.pose.position.x = 10.0;
    odometry_msg.pose.pose.position.y = 20.0;
    odometry_msg.pose.pose.position.z = 0.0;
    odometry_msg.twist.twist.linear.x = 5.0;
    odometry_msg.twist.twist.linear.y = 0.0;
    odometry_msg.twist.twist.linear.z = 0.0;
    (void)node->odometry_pub.publish(odometry_msg);
    log_info("Published odometry: pos=(%.1f, %.1f, %.1f), vel=(%.1f, %.1f, %.1f)\n",
             odometry_msg.pose.pose.position.x, odometry_msg.pose.pose.position.y,
             odometry_msg.pose.pose.position.z,
             odometry_msg.twist.twist.linear.x, odometry_msg.twist.twist.linear.y,
             odometry_msg.twist.twist.linear.z);

    // Publish Acceleration message
    AccelerationMsg acceleration_msg{};
    acceleration_msg.header.stamp = current_time;
    acceleration_msg.header.frame_id = base_link_frame_id;
    acceleration_msg.accel.accel.linear.x = 2.0;
    acceleration_msg.accel.accel.linear.y = 0.0;
    acceleration_msg.accel.accel.linear.z = 0.0;
    acceleration_msg.accel.accel.angular.x = 0.0;
    acceleration_msg.accel.accel.angular.y = 0.0;
    acceleration_msg.accel.accel.angular.z = 0.1;
    (void)node->acceleration_pub.publish(acceleration_msg);
    log_info("Published acceleration: linear=(%.1f, %.1f, %.1f), angular=(%.1f, %.1f, %.1f)\n",
             acceleration_msg.accel.accel.linear.x, acceleration_msg.accel.accel.linear.y,
             acceleration_msg.accel.accel.linear.z,
             acceleration_msg.accel.accel.angular.x, acceleration_msg.accel.accel.angular.y,
             acceleration_msg.accel.accel.angular.z);

    // Publish OperationModeState message
    OperationModeStateMsg operation_mode_msg{};
    operation_mode_msg.stamp = current_time;
    operation_mode_msg.mode = 1;
    operation_mode_msg.is_autoware_control_enabled = true;
    operation_mode_msg.is_in_transition = false;
    (void)node->operation_mode_pub.publish(operation_mode_msg);
    log_info("Published operation mode: mode=%d, autoware_enabled=%d, in_transition=%d\n",
             operation_mode_msg.mode, operation_mode_msg.is_autoware_control_enabled,
             operation_mode_msg.is_in_transition);

    log_info("--------------------------------\n");
    spin_for_ms(PUBLISH_PERIOD_MS);
  }

  return 0;
}
