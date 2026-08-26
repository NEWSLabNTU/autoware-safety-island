// Phase 3 W1 — DUAL-MODE TU (see common/node/node.hpp): nros ComponentNode
// controller on the Zephyr build, upstream raw-DDS controller on FreeRTOS.
#ifdef ASI_USE_NANO_ROS
// Copyright 2021 Tier IV, Inc. All rights reserved.
// Edited by: Oguz Ozturk 2025, ARM
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

#include "autoware/trajectory_follower_node/controller_node.hpp"
#include "autoware/mpc_lateral_controller/mpc_lateral_controller.hpp"
#include "autoware/pid_longitudinal_controller/pid_longitudinal_controller.hpp"
#include <autoware/trajectory_follower_base/lateral_controller_base.hpp>

#include "common/logger/logger.hpp"
#include "common/diag/trace_marker.hpp"
#include "common/clock/clock.hpp"
using namespace common::logger;

// Phase 2.A — the node name (I2) and topic strings (I3) are no longer
// inline literals here; they are sourced from the controller_pkg Node
// pkg's single declared-defaults header. A Phase 2.B launch.xml remaps
// them; these constants are the unchanged-behaviour `from=` defaults.
#include "controller_pkg/node_identity.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace autoware::motion::control::trajectory_follower_node
{
// Phase 242.5 (RFC-0044) — construct-with-handle ctor. The entry hands the
// executor-bound handle post-`nros::init`; `ComponentNode(handle, name)` creates
// the owned node, then the body wires the 5 subs / 3 pubs / 1 timer + MPC/PID.
// The per-node pthread spin of the legacy shim is gone — the executor drives us.
Controller::Controller(nros::NodeHandle handle)
  : nros::ComponentNode(handle, controller_pkg::node_identity::DEFAULT_NODE_NAME)
{
  const double ctrl_period = declare_parameter<double>("ctrl_period", 0.15);  // TODO: Orignal autoware period is 0.03 30ms
  timeout_thr_sec_ = declare_parameter<double>("timeout_thr_sec", 0.5);

  const auto lateral_controller_mode =
    getLateralControllerMode(declare_parameter<std::string>("lateral_controller_mode", "mpc"));
  log_debug("Lateral controller mode: %d", lateral_controller_mode);
  switch (lateral_controller_mode) {
    case LateralControllerMode::MPC: {
      lateral_controller_ =
        std::make_shared<mpc_lateral_controller::MpcLateralController>(*this);
      break;
    }
    default:
      log_error("[LateralController] invalid algorithm");
      std::exit(1);
  }

  const auto longitudinal_controller_mode =
    getLongitudinalControllerMode(declare_parameter<std::string>("longitudinal_controller_mode", "pid"));
  log_debug("Longitudinal controller mode: %d", longitudinal_controller_mode);
  switch (longitudinal_controller_mode) {
    case LongitudinalControllerMode::PID: {
      longitudinal_controller_ =
        std::make_shared<pid_longitudinal_controller::PidLongitudinalController>(*this);
      break;
    }
    default:
      log_error("[LongitudinalController] invalid algorithm");
      std::exit(1);
  }

  // Timer — RFC-0044 typed member timer (`void Controller::callbackTimerControl()`),
  // in its own callback group (RFC-0047) so the bringup's [tiers.control]
  // binds it to a real-time scheduling context; the subscriptions below stay
  // in the node's default context (see header note).
  {
    const auto period_ms = static_cast<uint64_t>(ctrl_period * 1000);
    create_timer_in<Controller, &Controller::callbackTimerControl>(
      create_callback_group("control"), period_ms);
  }

  // Subscribers — RFC-0044 typed member-callback subscriptions. The wire type +
  // member callback are the only spellings; the executor arena owns the
  // subscriber (no descriptor sentinel, no `void*` ctx).
  namespace topics = controller_pkg::node_identity::topics;

  // Phase 3 W3.b — KEEP_LAST depth 1 on every input (upstream fix #42 ported
  // to the nros side): the controller only ever consumes the MOST RECENT
  // sample of each input, and its control cycle runs slower than the 10 Hz
  // producers, so any deeper reader history just buffers stale samples. With
  // real (>1400 B, ~8.8 KiB serialized) Autoware trajectories the raw-DDS
  // depth-500 default once grew the reader cache until the allocator aborted
  // (silent board death, upstream #42); the nros default depth of 10 is far
  // safer but still buffers 9 stale trajectories nobody reads. Depth 1 bounds
  // every input's cache to one sample regardless of message size.
  const nros::QoS latest_only = nros::QoS::default_profile().keep_last(1);

  create_subscription<SteeringReportMsg, Controller, &Controller::on_steering_status>(
    topics::SUB_STEERING_STATUS, latest_only);
  create_subscription<TrajectoryMsg_Raw, Controller, &Controller::on_trajectory>(
    topics::SUB_TRAJECTORY, latest_only);
  create_subscription<OdometryMsg, Controller, &Controller::on_odometry>(
    topics::SUB_ODOMETRY, latest_only);
  create_subscription<AccelWithCovarianceStampedMsg, Controller, &Controller::on_acceleration>(
    topics::SUB_ACCELERATION, latest_only);
  create_subscription<OperationModeStateMsg, Controller, &Controller::on_operation_mode_state>(
    topics::SUB_OPERATION_MODE_STATE, latest_only);

  // Phase 4 (0745 follow-up) — the deployment owns the output mode: read the
  // launch-seeded `control_output` param (declared in system.launch.xml),
  // falling back to the compile-time configuration when unseeded/unknown.
  {
    const std::string mode_str = declare_parameter<std::string>(
      "control_output", common::can::output_mode_name(
                          common::can::configured_control_command_output_mode()));
    output_mode_ = common::can::output_mode_from_name(
      mode_str.c_str(), common::can::configured_control_command_output_mode());
  }
  log_info("Control command output mode: %s", common::can::output_mode_name(output_mode_));

  // Publishers
  if (common::can::output_mode_uses_dds(output_mode_)) {
    control_cmd_pub_ = create_publisher<ControlMsg>(topics::PUB_CONTROL_CMD);
  }

  if (common::can::output_mode_uses_can(output_mode_)) {
    can_output_ = std::make_shared<common::can::ControlCommandCanOutput>();
    if (!can_output_->init()) {
      if (output_mode_ == common::can::ControlCommandOutputMode::CAN_ONLY) {
        log_error("CAN output initialization failed in CAN_ONLY mode");
        std::exit(1);
      }
      log_error("CAN output initialization failed; DDS output remains active in DDS_AND_CAN mode");
      can_output_.reset();
    }
  }

  pub_processing_time_lat_ms_ =
    create_publisher<Float64StampedMsg>(topics::PUB_PROCESSING_TIME_LAT_MS);
  pub_processing_time_lon_ms_ =
    create_publisher<Float64StampedMsg>(topics::PUB_PROCESSING_TIME_LON_MS);
}

// SUBSCRIBER CALLBACKS — RFC-0044 typed member callbacks. The executor
// deserializes the wire message and dispatches `const Msg&` directly to `this`
// (no `void* arg` re-cast). Logic is otherwise verbatim from the legacy shim.
void Controller::on_steering_status(const SteeringReportMsg& msg) {
  current_steering_ = msg;
  has_steering_ = true;
}

void Controller::on_operation_mode_state(const OperationModeStateMsg& msg) {
  current_operation_mode_ = msg;
  has_operation_mode_ = true;
}

void Controller::on_odometry(const OdometryMsg& msg) {
  current_odometry_ = msg;
  // `msg` is a deserialized sample whose char* members (header.frame_id,
  // child_frame_id) point into storage the subscriber may reclaim once this
  // callback returns. The controller only consumes the numeric pose/twist
  // fields, so drop the unused string pointers instead of retaining them as
  // dangling references into freed storage.
  current_odometry_.header.frame_id = nullptr;
  current_odometry_.child_frame_id = nullptr;
  has_odometry_ = true;
}

void Controller::on_acceleration(const AccelWithCovarianceStampedMsg& msg) {
  current_accel_ = msg;
  // Drop the loaned char* string (header.frame_id) — see on_odometry; only the
  // numeric accel fields are consumed.
  current_accel_.header.frame_id = nullptr;
  has_accel_ = true;
}

void Controller::on_trajectory(const TrajectoryMsg_Raw& msg) {
  // Copy the data instead of storing the pointer
  current_trajectory_ = TrajectoryMsg(&msg);  // Copy the entire message
  // TrajectoryMsg deep-copies points but its `header = msg.header` shallow-copies
  // the loaned char* frame_id — see on_odometry. Only the points/header.stamp are
  // consumed, so drop the dangling string pointer rather than retaining it
  // (publishPredictedTraj() is currently disabled, but this keeps the field safe
  // for any future reader).
  current_trajectory_.header.frame_id = nullptr;
  has_trajectory_ = true;
  last_trajectory_time_ = Clock::now();
}

Controller::LateralControllerMode Controller::getLateralControllerMode(
  const std::string & controller_mode) const
{
  if (controller_mode == "mpc") return LateralControllerMode::MPC;

  return LateralControllerMode::INVALID;
}

Controller::LongitudinalControllerMode Controller::getLongitudinalControllerMode(
  const std::string & controller_mode) const
{
  if (controller_mode == "pid") return LongitudinalControllerMode::PID;

  return LongitudinalControllerMode::INVALID;
}

bool Controller::processData()
{
  bool is_ready = true;

  const auto & logData = [this](const std::string & data_type) {
    log_info_throttle(("Waiting for " + data_type + " data").c_str());
  };

  if (!has_accel_) {
    logData("acceleration");
    is_ready = false;
  }
  if (!has_steering_) {
    logData("steering");
    is_ready = false;
  }
  if (!has_trajectory_) {
    logData("trajectory");
    is_ready = false;
  } else if ((Clock::now() - last_trajectory_time_) > timeout_thr_sec_) {
    // ASI safety hardening (2026-08-24): a silent planner must not leave the
    // island tracking its last sample forever (degenerate arrival slivers
    // included). Withhold commands; the vehicle gate's own timeout then owns
    // the stop.
    logData("fresh trajectory");
    is_ready = false;
  }
  if (!has_odometry_) {
    logData("odometry");
    is_ready = false;
  }
  if (!has_operation_mode_) {
    logData("operation mode");
    is_ready = false;
  }

  return is_ready;
}

bool Controller::isTimeOut(
  const trajectory_follower::LongitudinalOutput & lon_out,
  const trajectory_follower::LateralOutput & lat_out)
{
  const auto now = Clock::now();
  if ((now - Clock::toDouble(lat_out.control_cmd.stamp)) > timeout_thr_sec_) {
    log_warn_throttle("Lateral control command too old, control_cmd will not be published.");
    return true;
  }
  if ((now - Clock::toDouble(lon_out.control_cmd.stamp)) > timeout_thr_sec_) {
    log_warn_throttle("Longitudinal control command too old, control_cmd will not be published.");
    return true;
  }
  return false;
}

std::optional<trajectory_follower::InputData> Controller::createInputData()
{
  if (!processData()) {
    return {};
  }

  trajectory_follower::InputData input_data;
  input_data.current_trajectory = current_trajectory_;
  input_data.current_odometry = current_odometry_;
  input_data.current_steering = current_steering_;
  input_data.current_accel = current_accel_;
  input_data.current_operation_mode = current_operation_mode_;

  return input_data;
}

void Controller::callbackTimerControl()
{
  // log_debug("Timer control callback");

  // Cycle phase stopwatch (M2.1): one CYCLE line per cycle so the UART log shows
  // where the control period actually goes on hardware. Debug-only and compiled
  // out at the default INFO level (see PROFILE_* in logger.hpp).
  PROFILE_POINT(cyc_t0);

  // phase-6 W6: bracket the cycle in the CTF stream so its span can be read
  // against the thread switches and ISRs that happened inside it. The exit
  // marker carries WHY the cycle ended, so a trace distinguishes a real
  // control cycle from a safe-stop or a not-ready skip without the console.
  static uint32_t cycle_seq;
  const uint32_t this_cycle = ++cycle_seq;
  common::diag::trace_marker(common::diag::Marker::control_cycle_enter, this_cycle);

  // 1. create input data
  const auto input_data = createInputData();
  if (!input_data) {
    // ASI safety hardening (phase-4 driving re-baseline defect, 2026-08-24):
    // SILENCE IS NOT SAFE. Publishing nothing leaves whatever the island last
    // emitted latched in the vehicle gate / actuator — observed as a
    // full-steer, max-speed circle after the planner went quiet. A safety
    // island that cannot compute a command must SAY SO by commanding a stop,
    // every cycle, for as long as its inputs are missing or stale.
    log_info_throttle("Inputs not ready — commanding safe stop.");
    publishSafeStopCommand();
    common::diag::trace_marker(common::diag::Marker::control_cycle_exit,
      static_cast<uint32_t>(common::diag::CycleOutcome::safe_stop));
    return;
  }

  log_debug("Input data created");

  // 2. check if controllers are ready
  const bool is_lat_ready = lateral_controller_->isReady(*input_data);
  const bool is_lon_ready = longitudinal_controller_->isReady(*input_data);
  if (!is_lat_ready || !is_lon_ready) {
    log_info_throttle("Control is skipped since lateral and/or longitudinal controllers are not ready to run.");
    common::diag::trace_marker(common::diag::Marker::control_cycle_exit,
      static_cast<uint32_t>(common::diag::CycleOutcome::not_ready));
    return;
  }

  log_debug("Controllers are ready");

  PROFILE_POINT(cyc_t_ready);

  // 3. run controllers
  stop_watch_.tic("lateral");
  const auto lat_out = lateral_controller_->run(*input_data);
  stop_watch_.toc("lateral");
  log_debug("Lateral controller elapsed time: %f", stop_watch_.toc("lateral"));

  log_debug("-------LAT OUT--", 0);
  log_debug("Lateral output: %f", lat_out.control_cmd.steering_tire_angle);
  log_debug("Lateral steering tire rotation rate: %f", lat_out.control_cmd.steering_tire_rotation_rate);
  log_debug("Lateral is defined steering tire rotation rate: %s", lat_out.control_cmd.is_defined_steering_tire_rotation_rate ? "true" : "false");

  publishProcessingTime(stop_watch_.toc("lateral"), pub_processing_time_lat_ms_);

  PROFILE_POINT(cyc_t_lat);

  stop_watch_.tic("longitudinal");
  const auto lon_out = longitudinal_controller_->run(*input_data);
  stop_watch_.toc("longitudinal");
  log_debug("Longitudinal controller elapsed time: %f", stop_watch_.toc("longitudinal"));

  // TODO: do not calculate jerk here, it is not used !
  log_debug("-------LON OUT--", 0);
  log_debug("Longitudinal output: %f", lon_out.control_cmd.velocity);
  log_debug("Longitudinal acceleration: %f", lon_out.control_cmd.acceleration);
  log_debug("Longitudinal is defined acceleration: %s", lon_out.control_cmd.is_defined_acceleration ? "true" : "false");
  log_debug("Longitudinal is defined jerk: %s", lon_out.control_cmd.is_defined_jerk ? "true" : "false");
  log_debug("-------------------------------");

  publishProcessingTime(stop_watch_.toc("longitudinal"), pub_processing_time_lon_ms_);

  log_debug("Controllers ran");

  PROFILE_POINT(cyc_t_lon);

  // 4. sync with each other controllers
  longitudinal_controller_->sync(lat_out.sync_data);
  lateral_controller_->sync(lon_out.sync_data);

  log_debug("Controllers synced");

  // TODO(Horibe): Think specification. This comes from the old implementation.
  // if (isTimeOut(lon_out, lat_out)) return;

  // 5. publish control command
  publishControlCommand(lon_out, lat_out);

  PROFILE_POINT(cyc_t_end);
  PROFILE_LOG("CYCLE in=%.1f lat=%.1f lon=%.1f pub=%.1f total=%.1f [ms]",
    PROFILE_MS(cyc_t0, cyc_t_ready), PROFILE_MS(cyc_t_ready, cyc_t_lat),
    PROFILE_MS(cyc_t_lat, cyc_t_lon), PROFILE_MS(cyc_t_lon, cyc_t_end),
    PROFILE_MS(cyc_t0, cyc_t_end));

  common::diag::trace_marker(common::diag::Marker::control_cycle_exit,
    static_cast<uint32_t>(common::diag::CycleOutcome::commanded));

  // 6. Reset flags for next cycle
  // TODO: Check if this is required, autoware version keeps publishing even there is no new data
  // reset_data_flags();
}

void Controller::publishControlCommand(
  const trajectory_follower::LongitudinalOutput & lon_out,
  const trajectory_follower::LateralOutput & lat_out)
{
  ControlMsg out{};
  out.stamp = Clock::toRosTime(Clock::now());
  out.lateral.steering_tire_angle = lat_out.control_cmd.steering_tire_angle;
  out.lateral.steering_tire_rotation_rate = lat_out.control_cmd.steering_tire_rotation_rate;
  out.lateral.is_defined_steering_tire_rotation_rate = lat_out.control_cmd.is_defined_steering_tire_rotation_rate;
  out.lateral.stamp = out.stamp;
  out.longitudinal = lon_out.control_cmd;

  // ASI safety hardening (phase-4 driving re-baseline defect, 2026-08-24):
  // a non-finite command NEVER leaves the island. NaN escaped the controller
  // internals once (ego past trajectory end -> interpolation NaN) and the
  // failure direction was +accel, not stop. Last line of defense: replace a
  // non-finite command with the safe-stop profile and say so.
  if (!std::isfinite(out.longitudinal.velocity) ||
      !std::isfinite(out.longitudinal.acceleration) ||
      !std::isfinite(out.lateral.steering_tire_angle) ||
      !std::isfinite(out.lateral.steering_tire_rotation_rate)) {
    log_error("Non-finite control command blocked (vel %f acc %f steer %f rate %f) — "
              "substituting safe stop",
              (double)out.longitudinal.velocity, (double)out.longitudinal.acceleration,
              (double)out.lateral.steering_tire_angle,
              (double)out.lateral.steering_tire_rotation_rate);
    out = makeSafeStopCommand();
  }

  emitControlCommand(out);
}

// The braking command the island falls back to whenever it cannot compute a
// real one: hold the last MEASURED steering angle (never a computed one, which
// is what may be corrupt), zero velocity, firm decel. Deliberately a full
// command and not silence — see callbackTimerControl.
ControlMsg Controller::makeSafeStopCommand()
{
  ControlMsg out{};
  out.stamp = Clock::toRosTime(Clock::now());
  const float held_steer = std::isfinite(current_steering_.steering_tire_angle)
                             ? current_steering_.steering_tire_angle : 0.0f;
  out.lateral.stamp = out.stamp;
  out.lateral.steering_tire_angle = held_steer;
  out.lateral.steering_tire_rotation_rate = 0.0f;
  out.lateral.is_defined_steering_tire_rotation_rate = true;
  out.longitudinal.stamp = out.stamp;
  out.longitudinal.velocity = 0.0f;
  out.longitudinal.acceleration = -2.5f;
  out.longitudinal.is_defined_acceleration = true;
  out.longitudinal.is_defined_jerk = false;
  return out;
}

void Controller::publishSafeStopCommand()
{
  ControlMsg out = makeSafeStopCommand();
  emitControlCommand(out);
}

void Controller::emitControlCommand(const ControlMsg & out)
{

  if (common::can::output_mode_uses_dds(output_mode_)) {
    if (control_cmd_pub_.publish(out).ok()) {
      log_debug("Control command published over DDS");
    } else {
      log_error("Control command not published over DDS");
    }
  }

  if (common::can::output_mode_uses_can(output_mode_)) {
    if (!can_output_ || !can_output_->send(out, output_mode_)) {
      if (output_mode_ == common::can::ControlCommandOutputMode::CAN_ONLY) {
        log_error("Control command not sent over CAN in CAN_ONLY mode");
      } else {
        log_warn_throttle("Control command not sent over CAN; DDS output remains active");
      }
    } else {
      log_debug("Control command sent over CAN");
    }
  }
}

void Controller::publishProcessingTime(
  const double t_ms, nros::Publisher<Float64StampedMsg>& pub)
{
  Float64StampedMsg msg{};
  msg.stamp = Clock::toRosTime(Clock::now());
  msg.data = t_ms;
  (void)pub.publish(msg);
}
}  // namespace autoware::motion::control::trajectory_follower_node

#else  // !ASI_USE_NANO_ROS — upstream raw-DDS controller (FreeRTOS)
// Copyright 2021 Tier IV, Inc. All rights reserved.
// Edited by: Oguz Ozturk 2025, ARM
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

#include "autoware/trajectory_follower_node/controller_node.hpp"
#include "autoware/mpc_lateral_controller/mpc_lateral_controller.hpp"
#include "autoware/pid_longitudinal_controller/pid_longitudinal_controller.hpp"
#include <autoware/trajectory_follower_base/lateral_controller_base.hpp>

#include "common/logger/logger.hpp"
#include "common/clock/clock.hpp"
using namespace common::logger;

#include "platform/platform_threading.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

// static K_THREAD_STACK_DEFINE(node_stack, CONFIG_THREAD_STACK_SIZE)  __aligned(4);  // TODO: may be needed for possible eigen memory issues
static K_THREAD_STACK_DEFINE(node_stack, CONFIG_THREAD_STACK_SIZE);
#define STACK_SIZE (K_THREAD_STACK_SIZEOF(node_stack))

namespace autoware::motion::control::trajectory_follower_node
{
Controller::Controller() : Node("controller", node_stack, STACK_SIZE)
{
  using std::placeholders::_1;

  const double ctrl_period = declare_parameter<double>("ctrl_period", 0.15);  // TODO: Orignal autoware period is 0.03 30ms
  timeout_thr_sec_ = declare_parameter<double>("timeout_thr_sec", 0.5);

  const auto lateral_controller_mode =
    getLateralControllerMode(declare_parameter<std::string>("lateral_controller_mode", "mpc"));
  log_debug("Lateral controller mode: %d", lateral_controller_mode);
  switch (lateral_controller_mode) {
    case LateralControllerMode::MPC: {
      lateral_controller_ =
        std::make_shared<mpc_lateral_controller::MpcLateralController>(*this);
      break;
    }
    default:
      log_error("[LateralController] invalid algorithm");
      std::exit(1);
  }

  const auto longitudinal_controller_mode =
    getLongitudinalControllerMode(declare_parameter<std::string>("longitudinal_controller_mode", "pid"));
  log_debug("Longitudinal controller mode: %d", longitudinal_controller_mode);
  switch (longitudinal_controller_mode) {
    case LongitudinalControllerMode::PID: {
      longitudinal_controller_ =
        std::make_shared<pid_longitudinal_controller::PidLongitudinalController>(*this);
      break;
    }
    default:
      log_error("[LongitudinalController] invalid algorithm");
      std::exit(1);
  }

  // Timer
  {
    const auto period_ms = ctrl_period*1000;
    create_timer(period_ms, [this]() { callbackTimerControl(); });
  }

  // Subscribers
  auto subscriber_steering_status = create_subscription<SteeringReportMsg>("/vehicle/status/steering_status",
                                                              &autoware_vehicle_msgs_msg_SteeringReport_desc,
                                                              callbackSteeringStatus, this);
  auto subscriber_trajectory = create_subscription<TrajectoryMsg_Raw>("/planning/scenario_planning/trajectory",
                                                              &autoware_planning_msgs_msg_Trajectory_desc,
                                                              callbackTrajectory, this);
  auto subscriber_odometry = create_subscription<OdometryMsg>("/localization/kinematic_state",
                                                              &nav_msgs_msg_Odometry_desc,
                                                              callbackOdometry, this);
  auto subscriber_acceleration = create_subscription<AccelWithCovarianceStampedMsg>("/localization/acceleration",
                                                              &geometry_msgs_msg_AccelWithCovarianceStamped_desc,
                                                              callbackAcceleration, this);
  auto subscriber_operation_mode_state = create_subscription<OperationModeStateMsg>("/system/operation_mode/state",
                                                              &autoware_adapi_v1_msgs_msg_OperationModeState_desc,
                                                              callbackOperationModeState, this);
    
  output_mode_ = common::can::configured_control_command_output_mode();
  log_info("Control command output mode: %s", common::can::output_mode_name(output_mode_));

  // Publishers
  if (common::can::output_mode_uses_dds(output_mode_)) {
    control_cmd_pub_ = create_publisher<ControlMsg>(
      "/control/trajectory_follower/control_cmd", &autoware_control_msgs_msg_Control_desc);
  }

  if (common::can::output_mode_uses_can(output_mode_)) {
    can_output_ = std::make_shared<common::can::ControlCommandCanOutput>();
    if (!can_output_->init()) {
      if (output_mode_ == common::can::ControlCommandOutputMode::CAN_ONLY) {
        log_error("CAN output initialization failed in CAN_ONLY mode");
        std::exit(1);
      }
      log_error("CAN output initialization failed; DDS output remains active in DDS_AND_CAN mode");
      can_output_.reset();
    }
  }

  pub_processing_time_lat_ms_ =
    create_publisher<Float64StampedMsg>("/control/trajectory_follower/lateral/debug/processing_time_ms", &tier4_debug_msgs_msg_Float64Stamped_desc);
  pub_processing_time_lon_ms_ =
    create_publisher<Float64StampedMsg>("/control/trajectory_follower/longitudinal/debug/processing_time_ms", &tier4_debug_msgs_msg_Float64Stamped_desc);
}

// SUBSCRIBER CALLBACKS
void Controller::callbackSteeringStatus(const SteeringReportMsg* msg, void* arg) {
  // static int count = 0;
  // log_debug("-------STEERING STATUS----IDX %d----", count++);
  // log_debug("Timestamp: %ld", Clock::toDouble(msg->stamp));
  // log_debug("Received steering status: %f", msg->steering_tire_angle);
  // log_debug("--------------------------------");

  // Put data into state pointers
  Controller* controller = static_cast<Controller*>(arg);
  controller->current_steering_ = *msg;
  controller->has_steering_ = true;
}

void Controller::callbackOperationModeState(const OperationModeStateMsg* msg, void* arg) {
  // static int count = 0;
  // log_debug("-------OPERATION MODE STATE----IDX %d----", count++);
  // log_debug("Timestamp: %ld", Clock::toDouble(msg->stamp));
  // log_debug("Mode: %d", msg->mode);
  // log_debug("Autoware control enabled: %d", msg->is_autoware_control_enabled);
  // log_debug("In transition: %d", msg->is_in_transition);
  // log_debug("--------------------------------");

  // Put data into state pointers
  Controller* controller = static_cast<Controller*>(arg);
  controller->current_operation_mode_ = *msg;
  controller->has_operation_mode_ = true;
}

void Controller::callbackOdometry(const OdometryMsg* msg, void* arg) {
  // static int count = 0;
  // log_debug("-------ODOMETRY----IDX %d----", count++);
  // log_debug("Timestamp: %ld", Clock::toDouble(msg->stamp));
  // log_debug("Position: %lf, %lf, %lf", msg->pose.pose.position.x, msg->pose.pose.position.y, msg->pose.pose.position.z);
  // log_debug("Linear Twist: %lf, %lf, %lf", msg->twist.twist.linear.x, msg->twist.twist.linear.y, msg->twist.twist.linear.z);
  // log_debug("-------------------------------");

  // Put data into state pointers
  Controller* controller = static_cast<Controller*>(arg);
  controller->current_odometry_ = *msg;
  // *msg is a shallow copy of a CycloneDDS loaned sample: its char* members
  // (header.frame_id, child_frame_id) point into storage the subscriber returns
  // via dds_return_loan() the moment this callback returns. The controller only
  // consumes the numeric pose/twist fields, so drop the unused string pointers
  // instead of retaining them as dangling references into freed loan storage.
  controller->current_odometry_.header.frame_id = nullptr;
  controller->current_odometry_.child_frame_id = nullptr;
  controller->has_odometry_ = true;
}

void Controller::callbackAcceleration(const AccelWithCovarianceStampedMsg* msg, void* arg) {
  // static int count = 0;
  // log_debug("-------ACCELERATION----IDX %d----", count++);
  // log_debug("Timestamp: %ld", Clock::toDouble(msg->stamp));
  // log_debug("Linear acceleration: %lf, %lf, %lf", msg->accel.accel.linear.x, msg->accel.accel.linear.y, msg->accel.accel.linear.z);
  // log_debug("Angular acceleration: %lf, %lf, %lf", msg->accel.accel.angular.x, msg->accel.accel.angular.y, msg->accel.accel.angular.z);
  // log_debug("-------------------------------");

  // Put data into state pointers
  Controller* controller = static_cast<Controller*>(arg);
  controller->current_accel_ = *msg;
  // Drop the loaned char* string (header.frame_id) before dds_return_loan() runs
  // — see callbackOdometry; only the numeric accel fields are consumed.
  controller->current_accel_.header.frame_id = nullptr;
  controller->has_accel_ = true;
}

void Controller::callbackTrajectory(const TrajectoryMsg_Raw* msg, void* arg) {
  // static int count = 0;
  // log_debug("-------TRAJECTORY----IDX %d----", count++);
  // log_debug("Timestamp: %f", Clock::toDouble(msg->header.stamp));
  // log_debug("Trajectory size: %u", msg->points._length);
  // log_debug("-------------------------------");

  // Copy the data instead of storing the pointer
  Controller* controller = static_cast<Controller*>(arg);
  controller->current_trajectory_ = TrajectoryMsg(msg);  // Copy the entire message
  // TrajectoryMsg deep-copies points but its `header = msg->header` shallow-copies
  // the loaned char* frame_id, which dds_return_loan() frees once this callback
  // returns — see callbackOdometry. Only the points/header.stamp are consumed, so
  // drop the dangling string pointer rather than retaining it (publishPredictedTraj()
  // is currently disabled, but this keeps the field safe for any future reader).
  controller->current_trajectory_.header.frame_id = nullptr;
  controller->has_trajectory_ = true;
  controller->last_trajectory_time_ = Clock::now();
}

Controller::LateralControllerMode Controller::getLateralControllerMode(
  const std::string & controller_mode) const
{
  if (controller_mode == "mpc") return LateralControllerMode::MPC;

  return LateralControllerMode::INVALID;
}

Controller::LongitudinalControllerMode Controller::getLongitudinalControllerMode(
  const std::string & controller_mode) const
{
  if (controller_mode == "pid") return LongitudinalControllerMode::PID;

  return LongitudinalControllerMode::INVALID;
}

bool Controller::processData()
{
  bool is_ready = true;

  const auto & logData = [this](const std::string & data_type) {
    log_info_throttle(("Waiting for " + data_type + " data").c_str());
  };

  if (!has_accel_) {
    logData("acceleration");
    is_ready = false;
  }
  if (!has_steering_) {
    logData("steering");
    is_ready = false;
  }
  if (!has_trajectory_) {
    logData("trajectory");
    is_ready = false;
  } else if ((Clock::now() - last_trajectory_time_) > timeout_thr_sec_) {
    // ASI safety hardening (2026-08-24): a silent planner must not leave the
    // island tracking its last sample forever (degenerate arrival slivers
    // included). Withhold commands; the vehicle gate's own timeout then owns
    // the stop.
    logData("fresh trajectory");
    is_ready = false;
  }
  if (!has_odometry_) {
    logData("odometry");
    is_ready = false;
  }
  if (!has_operation_mode_) {
    logData("operation mode");
    is_ready = false;
  }

  return is_ready;
}

bool Controller::isTimeOut(
  const trajectory_follower::LongitudinalOutput & lon_out,
  const trajectory_follower::LateralOutput & lat_out)
{
  const auto now = Clock::now();
  if ((now - Clock::toDouble(lat_out.control_cmd.stamp)) > timeout_thr_sec_) {
    log_warn_throttle("Lateral control command too old, control_cmd will not be published.");
    return true;
  }
  if ((now - Clock::toDouble(lon_out.control_cmd.stamp)) > timeout_thr_sec_) {
    log_warn_throttle("Longitudinal control command too old, control_cmd will not be published.");
    return true;
  }
  return false;
}

std::optional<trajectory_follower::InputData> Controller::createInputData()
{
  if (!processData()) {
    return {};
  }

  trajectory_follower::InputData input_data;
  input_data.current_trajectory = current_trajectory_;
  input_data.current_odometry = current_odometry_;
  input_data.current_steering = current_steering_;
  input_data.current_accel = current_accel_;
  input_data.current_operation_mode = current_operation_mode_;

  return input_data;
}

void Controller::callbackTimerControl()
{
  // log_debug("Timer control callback");

  // Cycle phase stopwatch (M2.1): one CYCLE line per cycle so the UART log shows
  // where the control period actually goes on hardware. Debug-only and compiled
  // out at the default INFO level (see PROFILE_* in logger.hpp).
  PROFILE_POINT(cyc_t0);

  // 1. create input data
  const auto input_data = createInputData();
  if (!input_data) {
    // ASI safety hardening (phase-4 driving re-baseline defect, 2026-08-24):
    // SILENCE IS NOT SAFE. Publishing nothing leaves whatever the island last
    // emitted latched in the vehicle gate / actuator — observed as a
    // full-steer, max-speed circle after the planner went quiet. A safety
    // island that cannot compute a command must SAY SO by commanding a stop,
    // every cycle, for as long as its inputs are missing or stale.
    log_info_throttle("Inputs not ready — commanding safe stop.");
    publishSafeStopCommand();
    return;
  }

  log_debug("Input data created");

  // 2. check if controllers are ready
  const bool is_lat_ready = lateral_controller_->isReady(*input_data);
  const bool is_lon_ready = longitudinal_controller_->isReady(*input_data);
  if (!is_lat_ready || !is_lon_ready) {
    log_info_throttle("Control is skipped since lateral and/or longitudinal controllers are not ready to run.");
    return;
  }

  log_debug("Controllers are ready");

  PROFILE_POINT(cyc_t_ready);

  // 3. run controllers
  stop_watch_.tic("lateral");
  const auto lat_out = lateral_controller_->run(*input_data);
  stop_watch_.toc("lateral");
  log_debug("Lateral controller elapsed time: %f", stop_watch_.toc("lateral"));

  log_debug("-------LAT OUT--", 0);
  log_debug("Lateral output: %f", lat_out.control_cmd.steering_tire_angle);
  log_debug("Lateral steering tire rotation rate: %f", lat_out.control_cmd.steering_tire_rotation_rate);
  log_debug("Lateral is defined steering tire rotation rate: %s", lat_out.control_cmd.is_defined_steering_tire_rotation_rate ? "true" : "false");

  publishProcessingTime(stop_watch_.toc("lateral"), pub_processing_time_lat_ms_);

  PROFILE_POINT(cyc_t_lat);

  stop_watch_.tic("longitudinal");
  const auto lon_out = longitudinal_controller_->run(*input_data);
  stop_watch_.toc("longitudinal");
  log_debug("Longitudinal controller elapsed time: %f", stop_watch_.toc("longitudinal"));

  // TODO: do not calculate jerk here, it is not used !
  log_debug("-------LON OUT--", 0);
  log_debug("Longitudinal output: %f", lon_out.control_cmd.velocity);
  log_debug("Longitudinal acceleration: %f", lon_out.control_cmd.acceleration);
  log_debug("Longitudinal is defined acceleration: %s", lon_out.control_cmd.is_defined_acceleration ? "true" : "false");
  log_debug("Longitudinal is defined jerk: %s", lon_out.control_cmd.is_defined_jerk ? "true" : "false");
  log_debug("-------------------------------");

  publishProcessingTime(stop_watch_.toc("longitudinal"), pub_processing_time_lon_ms_);

  log_debug("Controllers ran");

  PROFILE_POINT(cyc_t_lon);

  // 4. sync with each other controllers
  longitudinal_controller_->sync(lat_out.sync_data);
  lateral_controller_->sync(lon_out.sync_data);

  log_debug("Controllers synced");

  // TODO(Horibe): Think specification. This comes from the old implementation.
  // if (isTimeOut(lon_out, lat_out)) return;

  // 5. publish control command
  publishControlCommand(lon_out, lat_out);

  PROFILE_POINT(cyc_t_end);
  PROFILE_LOG("CYCLE in=%.1f lat=%.1f lon=%.1f pub=%.1f total=%.1f [ms]",
    PROFILE_MS(cyc_t0, cyc_t_ready), PROFILE_MS(cyc_t_ready, cyc_t_lat),
    PROFILE_MS(cyc_t_lat, cyc_t_lon), PROFILE_MS(cyc_t_lon, cyc_t_end),
    PROFILE_MS(cyc_t0, cyc_t_end));

  // 6. Reset flags for next cycle
  // TODO: Check if this is required, autoware version keeps publishing even there is no new data
  // reset_data_flags();
}

void Controller::publishControlCommand(
  const trajectory_follower::LongitudinalOutput & lon_out,
  const trajectory_follower::LateralOutput & lat_out)
{
  ControlMsg out{};
  out.stamp = Clock::toRosTime(Clock::now());
  out.lateral.steering_tire_angle = lat_out.control_cmd.steering_tire_angle;
  out.lateral.steering_tire_rotation_rate = lat_out.control_cmd.steering_tire_rotation_rate;
  out.lateral.is_defined_steering_tire_rotation_rate = lat_out.control_cmd.is_defined_steering_tire_rotation_rate;
  out.lateral.stamp = out.stamp;
  out.longitudinal = lon_out.control_cmd;

  // ASI safety hardening (phase-4 driving re-baseline defect, 2026-08-24):
  // a non-finite command NEVER leaves the island. NaN escaped the controller
  // internals once (ego past trajectory end -> interpolation NaN) and the
  // failure direction was +accel, not stop. Last line of defense: replace a
  // non-finite command with the safe-stop profile and say so.
  if (!std::isfinite(out.longitudinal.velocity) ||
      !std::isfinite(out.longitudinal.acceleration) ||
      !std::isfinite(out.lateral.steering_tire_angle) ||
      !std::isfinite(out.lateral.steering_tire_rotation_rate)) {
    log_error("Non-finite control command blocked (vel %f acc %f steer %f rate %f) — "
              "substituting safe stop",
              (double)out.longitudinal.velocity, (double)out.longitudinal.acceleration,
              (double)out.lateral.steering_tire_angle,
              (double)out.lateral.steering_tire_rotation_rate);
    out = makeSafeStopCommand();
  }

  emitControlCommand(out);
}

// The braking command the island falls back to whenever it cannot compute a
// real one: hold the last MEASURED steering angle (never a computed one, which
// is what may be corrupt), zero velocity, firm decel. Deliberately a full
// command and not silence — see callbackTimerControl.
ControlMsg Controller::makeSafeStopCommand()
{
  ControlMsg out{};
  out.stamp = Clock::toRosTime(Clock::now());
  const float held_steer = std::isfinite(current_steering_.steering_tire_angle)
                             ? current_steering_.steering_tire_angle : 0.0f;
  out.lateral.stamp = out.stamp;
  out.lateral.steering_tire_angle = held_steer;
  out.lateral.steering_tire_rotation_rate = 0.0f;
  out.lateral.is_defined_steering_tire_rotation_rate = true;
  out.longitudinal.stamp = out.stamp;
  out.longitudinal.velocity = 0.0f;
  out.longitudinal.acceleration = -2.5f;
  out.longitudinal.is_defined_acceleration = true;
  out.longitudinal.is_defined_jerk = false;
  return out;
}

void Controller::publishSafeStopCommand()
{
  ControlMsg out = makeSafeStopCommand();
  emitControlCommand(out);
}

void Controller::emitControlCommand(const ControlMsg & out)
{

  if (common::can::output_mode_uses_dds(output_mode_)) {
    if (control_cmd_pub_ && control_cmd_pub_->publish(out)) {
      log_debug("Control command published over DDS");
    } else {
      log_error("Control command not published over DDS");
    }
  }

  if (common::can::output_mode_uses_can(output_mode_)) {
    if (!can_output_ || !can_output_->send(out, output_mode_)) {
      if (output_mode_ == common::can::ControlCommandOutputMode::CAN_ONLY) {
        log_error("Control command not sent over CAN in CAN_ONLY mode");
      } else {
        log_warn_throttle("Control command not sent over CAN; DDS output remains active");
      }
    } else {
      log_debug("Control command sent over CAN");
    }
  }
}

void Controller::publishProcessingTime(
  const double t_ms, const std::shared_ptr<Publisher<Float64StampedMsg>> pub)
{
  Float64StampedMsg msg{};
  msg.stamp = Clock::toRosTime(Clock::now());
  msg.data = t_ms;
  pub->publish(msg);
}
}  // namespace autoware::motion::control::trajectory_follower_node

#endif  // ASI_USE_NANO_ROS
