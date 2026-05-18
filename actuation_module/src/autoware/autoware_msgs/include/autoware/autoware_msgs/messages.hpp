#ifndef COMMON__DDS__MESSAGES_HPP_
#define COMMON__DDS__MESSAGES_HPP_

#include <vector>

#ifdef ASI_USE_NANO_ROS
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

// OperationModeState constants live as inline static members on the
// generated nros type. Redirect ASI's existing macros to them so
// `mpc_lateral_controller.cpp:236` etc. stay untouched.
#define OPERATION_MODE_STATE_UNKNOWN      autoware_adapi_v1_msgs::msg::OperationModeState::UNKNOWN
#define OPERATION_MODE_STATE_STOP         autoware_adapi_v1_msgs::msg::OperationModeState::STOP
#define OPERATION_MODE_STATE_AUTONOMOUS   autoware_adapi_v1_msgs::msg::OperationModeState::AUTONOMOUS
#define OPERATION_MODE_STATE_LOCAL        autoware_adapi_v1_msgs::msg::OperationModeState::LOCAL
#define OPERATION_MODE_STATE_REMOTE       autoware_adapi_v1_msgs::msg::OperationModeState::REMOTE

// Sentinel topic-descriptor stubs. The nros-cpp shim's
// `create_publisher` / `create_subscription` carry an ignored
// `const void*` second arg so existing controller call sites of the
// form
//   create_publisher<ControlMsg>("/topic", &<type>_desc);
// compile under both legacy and shim builds. Under the shim the
// pointer is never dereferenced; the struct is empty.
struct dds_topic_descriptor_t {};
inline constexpr dds_topic_descriptor_t autoware_vehicle_msgs_msg_SteeringReport_desc       {};
inline constexpr dds_topic_descriptor_t autoware_planning_msgs_msg_Trajectory_desc          {};
inline constexpr dds_topic_descriptor_t nav_msgs_msg_Odometry_desc                          {};
inline constexpr dds_topic_descriptor_t geometry_msgs_msg_AccelWithCovarianceStamped_desc   {};
inline constexpr dds_topic_descriptor_t autoware_adapi_v1_msgs_msg_OperationModeState_desc  {};
inline constexpr dds_topic_descriptor_t autoware_control_msgs_msg_Control_desc              {};
inline constexpr dds_topic_descriptor_t tier4_debug_msgs_msg_Float64Stamped_desc            {};

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
} TrajectoryMsg;

#else  // ASI_USE_NANO_ROS

// =============================================================================
// Legacy raw-Cyclone idlc-generated C structs.
// =============================================================================

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
} TrajectoryMsg;

#endif  // ASI_USE_NANO_ROS

#endif // COMMON__DDS__MESSAGES_HPP_