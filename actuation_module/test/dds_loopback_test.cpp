// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 5 W5 — ported off the polling shim (`common/node/node_nros.hpp`)
// onto the executor-dispatch `rclcpp::Node` (was `nros::ComponentNode`) the production image
// uses. The test keeps its own imperative `main()` (no generated Entry):
// `rclcpp::init_in()` + a bounded `rclcpp::spin_once()` loop replace the shim's
// poll thread.

#include <atomic>
#include <cstdlib>
#include <new>

#include <rclcpp/rclcpp.hpp>
// nano-ros's weak no-op nros_board_network_wait(). The FreeRTOS runner calls
// it through a plain extern, and this hand-written entry includes nothing else
// that emits it, so the FreeRTOS POSIX image would not link. Drop once the
// runner takes it as a weak reference, as the ThreadX runner does.
#include <rclc/detail/main.h>

#include "common/clock/clock.hpp"
#include "common/logger/logger.hpp"

// nros-mode umbrella: SteeringReportMsg aliases the generated C++ type.
#include "autoware/autoware_msgs/messages.hpp"

using namespace common::logger;

static std::atomic<int> steering_report_count{0};

class LoopbackNode : public rclcpp::Node {
public:
  rclcpp::Publisher<SteeringReportMsg> pub;

  explicit LoopbackNode(rclcpp::NodeHandle h)
  : rclcpp::Node(h, "dds_loopback_test")
  {
    NROS_SUBSCRIBE(SteeringReportMsg, on_steering_report,
                   "/vehicle/status/steering_status");
    pub = create_publisher_in<SteeringReportMsg>("/vehicle/status/steering_status");
  }

  void on_steering_report(const SteeringReportMsg & msg)
  {
    log_info("\n------ STEERING REPORT ------\n");
    log_info("Timestamp: %f\n", Clock::toDouble(msg.stamp));
    log_info("Steering tire angle: %f\n", msg.steering_tire_angle);
    log_info("-------------------------------\n");
    steering_report_count.fetch_add(1, std::memory_order_relaxed);
  }
};

alignas(LoopbackNode) static unsigned char g_node_buf[sizeof(LoopbackNode)];

// The hosted signature: on a FreeRTOS board nano-ros renames main() and calls
// it from the board's entry as main(int, char **) (test_bringup's images).
// Zephyr declares `int main(void)` itself, so its test app keeps that one.
#if defined(__ZEPHYR__)
int main(void)
#else
int main(int /*argc*/, char ** /*argv*/)
#endif
{
  log_info("--------------------------------\n");
  log_info("Starting DDS loopback test\n");
  log_info("--------------------------------\n");
#if defined(PLATFORM_ZEPHYR)
  // Zephyr's DHCP client; a FreeRTOS board's network is up before main().
  log_info("Waiting for DHCP to get IP address...\n");
  sleep(CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX);
#endif

#if defined(CONFIG_ENABLE_SNTP) && CONFIG_ENABLE_SNTP
  if (Clock::init_clock_via_sntp() < 0) {
    log_error("Failed to set time using SNTP\n");
  } else {
    log_info("Time set using SNTP\n");
  }
#endif

  if (!rclcpp::init_in().ok()) {
    log_error("rclcpp::init_in failed\n");
    std::exit(1);
  }
  rclcpp::NodeHandle handle(rclcpp::global_handle());
  auto * node = new (g_node_buf) LoopbackNode(handle);
  if (!node->ok()) {
    log_error("Failed to create DDS loopback node: %s (code=%d)\n",
              node->error_what(), node->error_code());
    std::exit(1);
  }

  // Publish once a second (spinning the executor in between so the
  // subscription dispatches), until the loopback delivered twice.
  for (int attempt = 0;
       attempt < 20 && steering_report_count.load(std::memory_order_relaxed) < 2;
       ++attempt) {
    SteeringReportMsg msg{};
    msg.stamp = Clock::toRosTime(Clock::now());
    msg.steering_tire_angle = 0.5;
    if (!node->pub.publish(msg).ok()) {
      log_error("Failed to publish DDS loopback steering report\n");
      return 1;
    }
    for (int i = 0; i < 100; ++i) {
      (void)rclcpp::spin_once(10);
    }
  }

  if (steering_report_count.load(std::memory_order_relaxed) < 2) {
    log_error("DDS loopback subscriber did not receive enough steering reports\n");
    return 1;
  }

  log_info("DDS loopback test passed\n");
  return 0;
}
