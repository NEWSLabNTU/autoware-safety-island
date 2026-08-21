#ifndef COMMON__DDS__MESSAGES_HPP_
#define COMMON__DDS__MESSAGES_HPP_

// Phase 3 W1 (nano-ros branch) — DUAL-MODE message umbrella:
//   * ASI_USE_NANO_ROS (defined by the Zephyr build, actuation_module/
//     CMakeLists.txt): nros-codegen C++ types + FixedSequence containers.
//   * otherwise (FreeRTOS platforms): upstream's CycloneDDS idlc C structs.
// Both expose the SAME `...Msg` alias surface, so the controller / MPC /
// PID code compiles unchanged either way.
#ifdef ASI_USE_NANO_ROS

#include <vector>

// =============================================================================
// Phase 1.7 — nano-ros nros-cpp type aliases
// =============================================================================
// Pulls in nros-codegen-generated C++ headers (one per ROS package) and
// re-exposes ASI's legacy `...Msg` aliases as their nros equivalents so
// controller / MPC / PID code compiles unchanged. Field names mirror
// the upstream .msg definitions, which match Cyclone-idlc's generated
// C struct field names — only the namespace + container types
// (FixedSequence / FixedString) differ.

#include "autoware_adapi_v1_msgs.hpp"
#include "autoware_control_msgs.hpp"
#include "autoware_perception_msgs.hpp"
#include "autoware_planning_msgs.hpp"
#include "autoware_vehicle_msgs.hpp"
#include "builtin_interfaces.hpp"
#include "geometry_msgs.hpp"
#include "nav_msgs.hpp"
#include "std_msgs.hpp"
#include "tier4_debug_msgs.hpp"

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
    // Truncates if the local vector exceeds the 250-point bound.
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


#else  // !ASI_USE_NANO_ROS — upstream CycloneDDS idlc path (FreeRTOS)

#include <vector>

#include "SteeringReport.h"
#include "Trajectory.h"
#include "Odometry.h"
#include "AccelWithCovarianceStamped.h"
#include "OperationModeState.h"
#include "Control.h"
#include "Longitudinal.h"
#include "Lateral.h"
#include "PoseStamped.h"
#include "Float64Stamped.h"
#include "TrajectoryPoint.h"
#include "Point.h"
#include "Pose.h"
#include "PoseWithCovarianceStamped.h"
#include "Vector3.h"
#include "Quaternion.h"
#include "Transform.h"
#include "TransformStamped.h"
#include "Float32MultiArrayStamped.h"
#include "Float32Stamped.h"
#include "Twist.h"

using Float32MultiArrayStampedMsg = tier4_debug_msgs_msg_Float32MultiArrayStamped;
using Float32StampedMsg = tier4_debug_msgs_msg_Float32Stamped;
using TwistMsg = geometry_msgs_msg_Twist;
using LateralMsg = autoware_control_msgs_msg_Lateral;
using LongitudinalMsg = autoware_control_msgs_msg_Longitudinal;
using Vector3Msg = geometry_msgs_msg_Vector3;
using QuaternionMsg = geometry_msgs_msg_Quaternion;
using PoseWithCovarianceStampedMsg = geometry_msgs_msg_PoseWithCovarianceStamped;
using TransformMsg = geometry_msgs_msg_Transform;
using TransformStampedMsg = geometry_msgs_msg_TransformStamped;
using PointMsg = geometry_msgs_msg_Point;
using PoseMsg = geometry_msgs_msg_Pose;
using TrajectoryMsg_Raw = autoware_planning_msgs_msg_Trajectory;
using AccelerationMsg = geometry_msgs_msg_AccelWithCovarianceStamped;
using OperationModeStateMsg = autoware_adapi_v1_msgs_msg_OperationModeState;
using Float64StampedMsg = tier4_debug_msgs_msg_Float64Stamped;
using ControlMsg = autoware_control_msgs_msg_Control;
using OdometryMsg = nav_msgs_msg_Odometry;
using SteeringReportMsg = autoware_vehicle_msgs_msg_SteeringReport;
using AccelWithCovarianceStampedMsg = geometry_msgs_msg_AccelWithCovarianceStamped;
using TrajectoryPointMsg = autoware_planning_msgs_msg_TrajectoryPoint;
using PoseStampedMsg = geometry_msgs_msg_PoseStamped;

#define OPERATION_MODE_STATE_UNKNOWN autoware_adapi_v1_msgs_msg_OperationModeState_Constants_UNKNOWN
#define OPERATION_MODE_STATE_STOP autoware_adapi_v1_msgs_msg_OperationModeState_Constants_STOP
#define OPERATION_MODE_STATE_AUTONOMOUS autoware_adapi_v1_msgs_msg_OperationModeState_Constants_AUTONOMOUS
#define OPERATION_MODE_STATE_LOCAL autoware_adapi_v1_msgs_msg_OperationModeState_Constants_LOCAL
#define OPERATION_MODE_STATE_REMOTE autoware_adapi_v1_msgs_msg_OperationModeState_Constants_REMOTE

// TODO: This is a temporary solution to convert the raw DDS sequence to a vector
typedef struct TrajectoryMsg
{
    struct std_msgs_msg_Header header;
    std::vector<autoware_planning_msgs_msg_TrajectoryPoint> points;
    
    TrajectoryMsg() { points.reserve(250); }  // Reserves capacity for 250 elements but vector is still empty
    
    TrajectoryMsg(const TrajectoryMsg_Raw* msg) {
        header = msg->header;
        points.reserve(250);  // Reserve capacity first
        points.assign(msg->points._buffer, msg->points._buffer + msg->points._length);
    }

    // Phase 3 W1 — parity with the nros-mode wrapper: the vendored MPC
    // publishes `predicted_traj.to_raw()`. The returned raw's `points`
    // sequence BORROWS this wrapper's vector storage (no allocation);
    // valid only while the wrapper outlives the publish call.
    TrajectoryMsg_Raw to_raw() const {
        TrajectoryMsg_Raw raw;
        raw.header = header;
        raw.points._buffer = const_cast<autoware_planning_msgs_msg_TrajectoryPoint*>(points.data());
        raw.points._length = static_cast<uint32_t>(points.size());
        raw.points._maximum = static_cast<uint32_t>(points.capacity());
        raw.points._release = false;
        return raw;
    }
} TrajectoryMsg;


#endif  // ASI_USE_NANO_ROS

#endif  // COMMON__DDS__MESSAGES_HPP_
