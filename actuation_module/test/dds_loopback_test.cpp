// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 5 W5 — ported off the polling shim (`common/node/node_nros.hpp`)
// onto the executor-dispatch `nros::ComponentNode` the production image
// uses. The test keeps its own imperative `main()` (no generated Entry):
// `nros::init()` + a bounded `nros::spin_once()` loop replace the shim's
// poll thread.

#include <atomic>
#include <cstdlib>
#include <new>

#include <nros/component_node.hpp>
#include <nros/nros.hpp>

#include "common/clock/clock.hpp"
#include "common/logger/logger.hpp"

// nros-mode umbrella: SteeringReportMsg aliases the generated C++ type.
#include "autoware/autoware_msgs/messages.hpp"

using namespace common::logger;

static std::atomic<int> steering_report_count{0};

class LoopbackNode : public nros::ComponentNode {
public:
  nros::Publisher<SteeringReportMsg> pub;

  explicit LoopbackNode(nros::NodeHandle h)
  : nros::ComponentNode(h, "dds_loopback_test")
  {
    NROS_SUBSCRIBE(SteeringReportMsg, on_steering_report,
                   "/vehicle/status/steering_status");
    pub = create_publisher<SteeringReportMsg>("/vehicle/status/steering_status");
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

int main(void)
{
  log_info("--------------------------------\n");
  log_info("Starting DDS loopback test\n");
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
      (void)nros::spin_once(10);
    }
  }

  if (steering_report_count.load(std::memory_order_relaxed) < 2) {
    log_error("DDS loopback subscriber did not receive enough steering reports\n");
    return 1;
  }

  log_info("DDS loopback test passed\n");
  return 0;
}
