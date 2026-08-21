// Copyright 2021 Tier IV, Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef AUTOWARE__TRAJECTORY_FOLLOWER_NODE__CONTROLLER_NODE_HPP_
#define AUTOWARE__TRAJECTORY_FOLLOWER_NODE__CONTROLLER_NODE_HPP_

// Phase 3 W1 — DUAL-MODE (see common/node/node.hpp): nros ComponentNode
// controller on the Zephyr build, upstream raw-DDS controller on FreeRTOS.
#ifdef ASI_USE_NANO_ROS

#include "autoware/trajectory_follower_base/control_horizon.hpp"
#include "autoware/trajectory_follower_base/lateral_controller_base.hpp"
#include "autoware/trajectory_follower_base/longitudinal_controller_base.hpp"
#include "autoware/trajectory_follower_node/visibility_control.hpp"
#include "autoware/universe_utils/system/stop_watch.hpp"
#include "autoware_vehicle_info_utils/vehicle_info_utils.hpp"
#include "common/can/control_command_can_output.hpp"
#include "common/can/control_command_output_mode.hpp"

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <memory>
#include <string>
#include <utility>
#include <vector>

// Phase 242.5 (RFC-0044) — the vendored controller is base-swapped off the
// legacy `common/node` shim onto `nros::ComponentNode`, the rclcpp-faithful
// IS-A-node base: identity in the ctor, typed member-callback subscriptions,
// value-returning parameter facade. The 5 subs / 3 pubs / 1 timer migrate 1:1;
// the MPC/PID control math is untouched.
#include <nros/component_node.hpp>
#include "autoware/autoware_msgs/messages.hpp"

namespace autoware::motion::control
{
using trajectory_follower::LateralOutput;
using trajectory_follower::LongitudinalOutput;

namespace trajectory_follower_node
{

using autoware::universe_utils::StopWatch;

namespace trajectory_follower = ::autoware::motion::control::trajectory_follower;

/// \classController
/// \brief The node class used for generating longitudinal control commands (velocity/acceleration)
class TRAJECTORY_FOLLOWER_PUBLIC Controller : public nros::ComponentNode
{
public:
  /// RFC-0044 construct-with-handle ctor: the entry placement-news this node
  /// with the executor-bound handle *after* `nros::init`; the body creates the
  /// node + all entities (subs/pubs/timer) and declares params.
  explicit Controller(nros::NodeHandle handle);
  virtual ~Controller() {}

private:
  void reset_data_flags()
  {
    has_accel_ = false;
    has_steering_ = false;
    has_odometry_ = false;
    has_trajectory_ = false;
  }

  double timeout_thr_sec_;
  std::optional<LongitudinalOutput> longitudinal_output_{std::nullopt};

  std::shared_ptr<trajectory_follower::LongitudinalControllerBase> longitudinal_controller_;
  std::shared_ptr<trajectory_follower::LateralControllerBase> lateral_controller_;

  // Subscribers — RFC-0044 typed member callbacks (`void on_X(const Msg&)`),
  // wired via create_subscription<Msg, Controller, &Controller::on_X>(topic).
  void on_steering_status(const SteeringReportMsg& msg);
  void on_operation_mode_state(const OperationModeStateMsg& msg);
  void on_odometry(const OdometryMsg& msg);
  void on_acceleration(const AccelWithCovarianceStampedMsg& msg);
  void on_trajectory(const TrajectoryMsg_Raw& msg);

  // Current Data
  TrajectoryMsg current_trajectory_;
  OdometryMsg current_odometry_;
  SteeringReportMsg current_steering_;
  AccelWithCovarianceStampedMsg current_accel_;
  /*
    mode: 1,
    is_autoware_control_enabled: true,
    is_in_transition: false,
    is_stop_mode_available: true,
    is_autonomous_mode_available: true,
    is_local_mode_available: true,
    is_remote_mode_available: true
  */
  OperationModeStateMsg current_operation_mode_ = {.mode = 1, .is_autoware_control_enabled = true, .is_in_transition = false, .is_stop_mode_available = true, .is_autonomous_mode_available = true, .is_local_mode_available = true, .is_remote_mode_available = true};

  bool has_trajectory_ = false;
  bool has_odometry_ = false;
  bool has_steering_ = false;
  bool has_accel_ = false;
  bool has_operation_mode_ = true;

  // Phase 4 (RFC-0047) — the control timer runs in its OWN callback group so
  // the deployment can bind it to a real-time tier ([tiers.control] +
  // group_tiers in controller_bringup/system.toml); the subscriptions stay in
  // the node's default context, so input deserialization cannot stall the
  // control period. (The group is a name token created inline at the timer
  // site — no member needed.)

  // Publishers — RFC-0044 value-typed `nros::Publisher<M>` members
  // (default-constructed; assigned from create_publisher<M>(topic) in the ctor).
  nros::Publisher<ControlMsg> control_cmd_pub_;
  common::can::ControlCommandOutputMode output_mode_{common::can::configured_control_command_output_mode()};
  std::shared_ptr<common::can::ControlCommandCanOutput> can_output_;
  nros::Publisher<Float64StampedMsg> pub_processing_time_lat_ms_;
  nros::Publisher<Float64StampedMsg> pub_processing_time_lon_ms_;
  
  enum class LateralControllerMode {
    INVALID = 0,
    MPC = 1,
    PURE_PURSUIT = 2,
  };
  enum class LongitudinalControllerMode {
    INVALID = 0,
    PID = 1,
  };

  /**
   * @brief compute control command, and publish periodically
   */
  std::optional<trajectory_follower::InputData> createInputData();

  //
  void callbackTimerControl();

  //
  bool processData();

  //
  bool isTimeOut(const LongitudinalOutput & lon_out, const LateralOutput & lat_out);

  //
  LateralControllerMode getLateralControllerMode(const std::string & algorithm_name) const;

  //
  LongitudinalControllerMode getLongitudinalControllerMode(
    const std::string & algorithm_name) const;

  //
  void publishControlCommand(const trajectory_follower::LongitudinalOutput & lon_out, const trajectory_follower::LateralOutput & lat_out);

  //
  void publishProcessingTime(
    const double t_ms, nros::Publisher<Float64StampedMsg>& pub);

  //
  StopWatch<std::chrono::milliseconds> stop_watch_;
};

}  // namespace trajectory_follower_node
}  // namespace autoware::motion::control


#else  // !ASI_USE_NANO_ROS — upstream raw-DDS controller (FreeRTOS)

#include "autoware/trajectory_follower_base/control_horizon.hpp"
#include "autoware/trajectory_follower_base/lateral_controller_base.hpp"
#include "autoware/trajectory_follower_base/longitudinal_controller_base.hpp"
#include "autoware/trajectory_follower_node/visibility_control.hpp"
#include "autoware/universe_utils/system/stop_watch.hpp"
#include "autoware_vehicle_info_utils/vehicle_info_utils.hpp"
#include "common/can/control_command_can_output.hpp"
#include "common/can/control_command_output_mode.hpp"

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "common/node/node.hpp"
#include "autoware/autoware_msgs/messages.hpp"

namespace autoware::motion::control
{
using trajectory_follower::LateralOutput;
using trajectory_follower::LongitudinalOutput;

namespace trajectory_follower_node
{

using autoware::universe_utils::StopWatch;

namespace trajectory_follower = ::autoware::motion::control::trajectory_follower;

/// \classController
/// \brief The node class used for generating longitudinal control commands (velocity/acceleration)
class TRAJECTORY_FOLLOWER_PUBLIC Controller : public Node
{
public:
  Controller();
  virtual ~Controller() {}

private:
  void reset_data_flags()
  {
    has_accel_ = false;
    has_steering_ = false;
    has_odometry_ = false;
    has_trajectory_ = false;
  }

  double timeout_thr_sec_;
  std::optional<LongitudinalOutput> longitudinal_output_{std::nullopt};

  std::shared_ptr<trajectory_follower::LongitudinalControllerBase> longitudinal_controller_;
  std::shared_ptr<trajectory_follower::LateralControllerBase> lateral_controller_;

  // Subscribers
  static void callbackSteeringStatus(const SteeringReportMsg* msg, void* arg);
  static void callbackOperationModeState(const OperationModeStateMsg* msg, void* arg);
  static void callbackOdometry(const OdometryMsg* msg, void* arg);
  static void callbackAcceleration(const AccelWithCovarianceStampedMsg* msg, void* arg);
  static void callbackTrajectory(const TrajectoryMsg_Raw* msg, void* arg);

  // Current Data
  TrajectoryMsg current_trajectory_;
  OdometryMsg current_odometry_;
  SteeringReportMsg current_steering_;
  AccelWithCovarianceStampedMsg current_accel_;
  /*
    mode: 1,
    is_autoware_control_enabled: true,
    is_in_transition: false,
    is_stop_mode_available: true,
    is_autonomous_mode_available: true,
    is_local_mode_available: true,
    is_remote_mode_available: true
  */
  OperationModeStateMsg current_operation_mode_ = {.mode = 1, .is_autoware_control_enabled = true, .is_in_transition = false, .is_stop_mode_available = true, .is_autonomous_mode_available = true, .is_local_mode_available = true, .is_remote_mode_available = true};

  bool has_trajectory_ = false;
  bool has_odometry_ = false;
  bool has_steering_ = false;
  bool has_accel_ = false;
  bool has_operation_mode_ = true;

  // Publishers
  std::shared_ptr<Publisher<ControlMsg>> control_cmd_pub_;
  common::can::ControlCommandOutputMode output_mode_{common::can::configured_control_command_output_mode()};
  std::shared_ptr<common::can::ControlCommandCanOutput> can_output_;
  std::shared_ptr<Publisher<Float64StampedMsg>> pub_processing_time_lat_ms_;
  std::shared_ptr<Publisher<Float64StampedMsg>> pub_processing_time_lon_ms_;
  
  enum class LateralControllerMode {
    INVALID = 0,
    MPC = 1,
    PURE_PURSUIT = 2,
  };
  enum class LongitudinalControllerMode {
    INVALID = 0,
    PID = 1,
  };

  /**
   * @brief compute control command, and publish periodically
   */
  std::optional<trajectory_follower::InputData> createInputData();

  //
  void callbackTimerControl();

  //
  bool processData();

  //
  bool isTimeOut(const LongitudinalOutput & lon_out, const LateralOutput & lat_out);

  //
  LateralControllerMode getLateralControllerMode(const std::string & algorithm_name) const;

  //
  LongitudinalControllerMode getLongitudinalControllerMode(
    const std::string & algorithm_name) const;

  //
  void publishControlCommand(const trajectory_follower::LongitudinalOutput & lon_out, const trajectory_follower::LateralOutput & lat_out);

  //
  void publishProcessingTime(
    const double t_ms, const std::shared_ptr<Publisher<Float64StampedMsg>> pub);

  //
  StopWatch<std::chrono::milliseconds> stop_watch_;
};

}  // namespace trajectory_follower_node
}  // namespace autoware::motion::control


#endif  // ASI_USE_NANO_ROS

#endif
