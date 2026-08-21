// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 5 W5 — ported off the polling shim (`common/node/node_nros.hpp`)
// onto the executor-dispatch `nros::ComponentNode` the production image
// uses. Callback dispatch now happens inside `nros::spin_once()` on the
// main thread, so the test state needs no mutex and the wait helper must
// spin the executor rather than sleep.
//
// Dropped with the shim (executor-owned lifecycle now):
//   * the spin()/stop() thread-management test — there is no per-node poll
//     thread to start/stop; the executor is driven by spin_once.
//   * the stop_timer test — a ComponentNode timer lives with its node
//     (nros::Timer's dtor cancels it); there is no mid-life stop API.

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <new>

#include <nros/component_node.hpp>
#include <nros/nros.hpp>

#include "common/clock/clock.hpp"
#include "common/logger/logger.hpp"
#include "autoware/autoware_msgs/messages.hpp"

using namespace common::logger;

// Test state — written only from callbacks dispatched inside spin_once()
// on this thread, so plain fields suffice.
struct TestState {
    struct {
        bool received{false};
        double x, y, z;
    } pose;
    struct {
        int count{0};
    } timer;

    void reset() {
        pose = {false, 0, 0, 0};
        timer = {0};
    }
};

static TestState g_state;

// Helper macros for test readability
#define TEST_START(name) \
    log_info("=== Testing " #name " ===\n"); \
    g_state.reset();

#define TEST_END(name) \
    log_info(#name " tests passed\n");

#define ASSERT_MSG(condition, message) \
    do { \
        if (!(condition)) { \
            log_error("Assertion failed: %s\n", message); \
            assert(false && message); \
        } \
    } while (0)

class TestNode : public nros::ComponentNode {
public:
    nros::Publisher<PoseStampedMsg> pose_pub;

    explicit TestNode(nros::NodeHandle h)
    : nros::ComponentNode(h, "test_node")
    {
        create_timer<TestNode, &TestNode::on_tick>(100);  // 10 Hz timer
        pose_pub = create_publisher<PoseStampedMsg>("test_pose");
        NROS_SUBSCRIBE(PoseStampedMsg, on_pose, "test_pose");
        // Backs the parameter write on_tick exercises from dispatch context.
        (void)declare_parameter<int64_t>("int_param", 0);
    }

    void on_tick()
    {
        g_state.timer.count++;
        log_info("Timer #%d\n", g_state.timer.count);
        // Exercise a parameter write from a dispatched callback.
        set_param<int64_t>("int_param", g_state.timer.count);
    }

    void on_pose(const PoseStampedMsg & msg)
    {
        g_state.pose = {true, msg.pose.position.x, msg.pose.position.y,
                        msg.pose.position.z};
        log_info("Received pose: (%.1f, %.1f, %.1f)\n",
                 msg.pose.position.x, msg.pose.position.y, msg.pose.position.z);
    }

    // The value-returning ComponentNode facade has no public set_parameter;
    // the backing ParameterServer (protected `params_`) does.
    template <typename T>
    bool set_param(const char * name, T value)
    {
        return params_.set_parameter(name, value).ok();
    }
};

// Spin the executor until `check()` holds or `timeout_ms` elapses. Dispatch
// happens inside spin_once, so this MUST spin, not sleep.
static bool spin_until(bool (*check)(), int timeout_ms = 2000)
{
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        (void)nros::spin_once(10);
        if (check()) return true;
    }
    return false;
}

static void verify_pose_reception(double x, double y, double z)
{
    ASSERT_MSG(g_state.pose.received, "Message should be received");
    ASSERT_MSG(g_state.pose.x == x, "X coordinate mismatch");
    ASSERT_MSG(g_state.pose.y == y, "Y coordinate mismatch");
    ASSERT_MSG(g_state.pose.z == z, "Z coordinate mismatch");
}

// Test cases
static void test_parameters(TestNode & node)
{
    TEST_START(Parameters)

    ASSERT_MSG(node.declare_parameter<bool>("enabled", true) == true,
               "Parameter declaration failed");
    ASSERT_MSG(node.has_parameter("enabled"), "Should have declared parameter");
    ASSERT_MSG(node.get_parameter<bool>("enabled") == true,
               "Parameter value retrieval failed");
    ASSERT_MSG(node.set_param<bool>("enabled", false), "Parameter set failed");
    ASSERT_MSG(node.get_parameter<bool>("enabled") == false,
               "Updated value retrieval failed");
    ASSERT_MSG(!node.has_parameter("disabled"),
               "Should not have undeclared parameter");
    ASSERT_MSG(!node.set_param<bool>("disabled", true),
               "Should not be able to set undeclared parameter");

    TEST_END(Parameters)
}

static void test_timer_operations(TestNode &)
{
    TEST_START(Timer Operations)

    // The 100 ms timer was created in the ctor; verify it fires under spin.
    ASSERT_MSG(spin_until([] { return g_state.timer.count >= 2; }),
               "Timer didn't trigger enough times");

    TEST_END(Timer Operations)
}

static void test_dds_communication(TestNode & node)
{
    TEST_START(DDS Communication)

    // Test message roundtrips (publisher + subscription wired in the ctor).
    for (int i = 0; i < 3; i++) {
        PoseStampedMsg msg{};
        msg.pose.position = {i * 1.0, i * 2.0, i * 3.0};
        ASSERT_MSG(node.pose_pub.publish(msg).ok(), "Publish should succeed");

        ASSERT_MSG(spin_until([] { return g_state.pose.received; }),
                   "Message delivery timeout");

        verify_pose_reception(i * 1.0, i * 2.0, i * 3.0);
        g_state.pose.received = false;  // Reset for the next message
    }

    TEST_END(DDS Communication)
}

static void test_clock_utils()
{
    TEST_START(Clock Utilities)

    // Test Clock::now() returns valid time
    double now = Clock::now();
    log_info("Current time: %f\n", now);
    ASSERT_MSG(now > 0, "Current time should be positive");

    // Test round-trip conversion: double -> ROS time -> double
    const double test_time = 1234.567;
    TimeMsg ros_time = Clock::toRosTime(test_time);

    // Verify conversion to ROS time
    ASSERT_MSG(ros_time.sec == 1234, "Seconds conversion error");
    ASSERT_MSG(ros_time.nanosec == 567000000, "Nanoseconds conversion error");

    // Verify round-trip conversion
    double converted_back = Clock::toDouble(ros_time);
    ASSERT_MSG(fabs(converted_back - test_time) < 1e-9, "Round-trip conversion error");

    // Test boundary/edge cases
    const double zero_time = 0.0;
    TimeMsg zero_ros_time = Clock::toRosTime(zero_time);
    ASSERT_MSG(zero_ros_time.sec == 0, "Zero seconds conversion error");
    ASSERT_MSG(zero_ros_time.nanosec == 0, "Zero nanoseconds conversion error");

    // Test very large time values
    const double large_time = 1e9;  // ~31.7 years
    TimeMsg large_ros_time = Clock::toRosTime(large_time);
    ASSERT_MSG(large_ros_time.sec == 1000000000, "Large time seconds conversion error");
    ASSERT_MSG(large_ros_time.nanosec == 0, "Large time nanoseconds conversion error");

    // Test very precise time values
    const double precise_time = 12.000000008;  // 12 seconds + 8 nanoseconds
    TimeMsg precise_ros_time = Clock::toRosTime(precise_time);
    ASSERT_MSG(precise_ros_time.sec == 12, "Precise time seconds conversion error");
    ASSERT_MSG(precise_ros_time.nanosec == 8, "Precise time nanoseconds conversion error");

    TEST_END(Clock Utilities)
}

alignas(TestNode) static unsigned char g_node_buf[sizeof(TestNode)];

int main()
{
    log_info("=== Starting Node Test Suite ===\n");
    log_info("Waiting for Network interface to be ready\n");
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
    auto * node = new (g_node_buf) TestNode(handle);
    ASSERT_MSG(node->ok(), "TestNode construction should succeed");

    test_parameters(*node);
    test_timer_operations(*node);
    test_dds_communication(*node);
    test_clock_utils();

    log_info("\n=== All Tests Passed ===\n");
    exit(0);
}
