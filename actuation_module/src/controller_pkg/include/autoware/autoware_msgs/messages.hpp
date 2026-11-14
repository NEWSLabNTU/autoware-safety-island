#ifndef COMMON__DDS__MESSAGES_HPP_
#define COMMON__DDS__MESSAGES_HPP_

// Phase 5 W3 — nros-only message umbrella: nros-codegen C++ types +
// FixedSequence containers behind the `...Msg` alias surface the
// controller / MPC / PID code compiles against. The CycloneDDS idlc C
// structs retired with the freertos-s32z2-legacy lane.

#include <vector>

// nros-codegen C++ headers, ROS-style (<pkg>/msg/<name>.hpp), for the types
// the `...Msg` aliases below re-expose under ASI's legacy names. The message
// packages are controller_pkg's <depend>s; the upstream ones are generated
// from the ROS / Autoware install, visionpilot_msgs and safety_island_msgs
// from their packages in this workspace.
#include <autoware_adapi_v1_msgs/msg/operation_mode_state.hpp>
#include <autoware_control_msgs/msg/control.hpp>
#include <autoware_control_msgs/msg/lateral.hpp>
#include <autoware_control_msgs/msg/longitudinal.hpp>
#include <autoware_planning_msgs/msg/trajectory.hpp>
#include <autoware_planning_msgs/msg/trajectory_point.hpp>
#include <autoware_vehicle_msgs/msg/steering_report.hpp>
#include <builtin_interfaces/msg/duration.hpp>
#include <builtin_interfaces/msg/time.hpp>
#include <geometry_msgs/msg/accel_with_covariance_stamped.hpp>
#include <geometry_msgs/msg/point.hpp>
#include <geometry_msgs/msg/pose.hpp>
#include <geometry_msgs/msg/pose_stamped.hpp>
#include <geometry_msgs/msg/pose_with_covariance_stamped.hpp>
#include <geometry_msgs/msg/quaternion.hpp>
#include <geometry_msgs/msg/transform.hpp>
#include <geometry_msgs/msg/transform_stamped.hpp>
#include <geometry_msgs/msg/twist.hpp>
#include <geometry_msgs/msg/vector3.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <safety_island_msgs/msg/approved_request.hpp>
#include <std_msgs/msg/bool.hpp>
#include <std_msgs/msg/header.hpp>
// nano-ros spells a digit-to-capital boundary without the underscore rosidl
// puts there (float32stamped.hpp, not float32_stamped.hpp); nano-ros issue
// 3882.
#include <tier4_debug_msgs/msg/float32multi_array_stamped.hpp>
#include <tier4_debug_msgs/msg/float32stamped.hpp>
#include <tier4_debug_msgs/msg/float64stamped.hpp>
#include <visionpilot_msgs/msg/driving_command.hpp>
#include <visionpilot_msgs/msg/driving_reference.hpp>

// ======================================================================
using Float32MultiArrayStampedMsg     = tier4_debug_msgs::msg::Float32MultiArrayStamped;
using Float32StampedMsg               = tier4_debug_msgs::msg::Float32Stamped;
using TwistMsg                        = geometry_msgs::msg::Twist;
using LateralMsg                      = autoware_control_msgs::msg::Lateral;
using LongitudinalMsg                 = autoware_control_msgs::msg::Longitudinal;
using Vector3Msg                      = geometry_msgs::msg::Vector3;
using QuaternionMsg                   = geometry_msgs::msg::Quaternion;
using PoseWithCovarianceStampedMsg    = geometry_msgs::msg::PoseWithCovarianceStamped;
using TransformMsg                    = geometry_msgs::msg::Transform;
using TransformStampedMsg             = geometry_msgs::msg::TransformStamped;
using PointMsg                        = geometry_msgs::msg::Point;
using PoseMsg                         = geometry_msgs::msg::Pose;
using TrajectoryMsg_Raw               = autoware_planning_msgs::msg::Trajectory;
using AccelerationMsg                 = geometry_msgs::msg::AccelWithCovarianceStamped;
using OperationModeStateMsg           = autoware_adapi_v1_msgs::msg::OperationModeState;
using Float64StampedMsg               = tier4_debug_msgs::msg::Float64Stamped;
using ControlMsg                      = autoware_control_msgs::msg::Control;
using OdometryMsg                     = nav_msgs::msg::Odometry;
using SteeringReportMsg               = autoware_vehicle_msgs::msg::SteeringReport;
using AccelWithCovarianceStampedMsg   = geometry_msgs::msg::AccelWithCovarianceStamped;
using TrajectoryPointMsg              = autoware_planning_msgs::msg::TrajectoryPoint;
using PoseStampedMsg                  = geometry_msgs::msg::PoseStamped;
using TimeMsg                         = builtin_interfaces::msg::Time;
using DurationMsg                     = builtin_interfaces::msg::Duration;
// Supervision (vp_si_control_contract, upstream #66): this workspace's packages.
using DrivingCommandMsg               = visionpilot_msgs::msg::DrivingCommand;
using DrivingReferenceMsg             = visionpilot_msgs::msg::DrivingReference;
using ApprovedRequestMsg              = safety_island_msgs::msg::ApprovedRequest;
using BoolMsg                         = std_msgs::msg::Bool;

// supervision octet values; keep in sync with safety_island_msgs/msg/ApprovedRequest.msg
#define SIR_DECISION_NORMAL 0
#define SIR_DECISION_SI_STOP 1
#define SIR_DECISION_HOLD 2
#define SIR_MODE_SI_CONTROL 0
#define SIR_MODE_VP_CONTROL 1
#define SIR_SOURCE_FOLLOWER 0
#define SIR_SOURCE_VP_COMMAND 1

// nros codegen emits message constants as `<MessageName>_<CONSTANT>`
// constexpr at namespace scope (per message_cpp.hpp.jinja template),
// NOT as inline static members. Redirect ASI's existing macros so
// `mpc_lateral_controller.cpp:236` etc. stay untouched.
#define OPERATION_MODE_STATE_UNKNOWN      autoware_adapi_v1_msgs::msg::OperationModeState_UNKNOWN
#define OPERATION_MODE_STATE_STOP         autoware_adapi_v1_msgs::msg::OperationModeState_STOP
#define OPERATION_MODE_STATE_AUTONOMOUS   autoware_adapi_v1_msgs::msg::OperationModeState_AUTONOMOUS
#define OPERATION_MODE_STATE_LOCAL        autoware_adapi_v1_msgs::msg::OperationModeState_LOCAL
#define OPERATION_MODE_STATE_REMOTE       autoware_adapi_v1_msgs::msg::OperationModeState_REMOTE

// (Phase 5 W5: the polling shim's sentinel `<type>_desc` stubs are gone —
// every nros-mode call site now uses ComponentNode's descriptor-less
// typed entities.)

// Conversion wrapper. Legacy version assigns from Cyclone's raw
// `_buffer`/`_length` sequence; the nros version copies via the
// FixedSequence iterators (std::array-like surface).
typedef struct TrajectoryMsg
{
    std_msgs::msg::Header header;
    std::vector<autoware_planning_msgs::msg::TrajectoryPoint> points;

    TrajectoryMsg() { points.reserve(250); }

    TrajectoryMsg(const TrajectoryMsg_Raw * msg)
    {
        header = msg->header;
        points.reserve(250);
        points.assign(msg->points.begin(), msg->points.end());
    }

    // Convert back to the nros-generated wire type for publish().
    // Truncates if the local vector exceeds the 250-point bound
    // (Trajectory.points in actuation_module/nros-codegen.toml).
    TrajectoryMsg_Raw to_raw() const
    {
        TrajectoryMsg_Raw raw;
        raw.header = header;
        const std::size_t n = points.size() > 250 ? 250 : points.size();
        for (std::size_t i = 0; i < n; ++i) {
            (void)raw.points.push_back(points[i]);
        }
        return raw;
    }
} TrajectoryMsg;

#endif  // COMMON__DDS__MESSAGES_HPP_
