// Copyright (c) 2024-2025, Arm Limited.
// SPDX-License-Identifier: Apache-2.0

#include "common/clock/clock.hpp"
#include "common/logger/logger.hpp"
using namespace common::logger;

#include "platform/platform_config.h"
#include "platform/platform_network.h"

#include "autoware/trajectory_follower_node/controller_node.hpp"

#include <nros/nros.hpp>

#ifdef CONFIG_NROS_RMW_CYCLONEDDS
#  define ASI_DOMAIN_ID CONFIG_NROS_CYCLONE_DOMAIN_ID
#else
#  define ASI_DOMAIN_ID CONFIG_NROS_DOMAIN_ID
#endif

int main(void)
{
    autoware::motion::control::trajectory_follower_node::Controller* controller;

    log_success("-----------------------------------------");
    log_success("ARM - Autoware: Actuation Safety Island");
    log_success("-----------------------------------------");
#if defined(CONFIG_NET_DHCPV4) && CONFIG_NET_DHCPV4
    log_info("Waiting for DHCP to get IP address...");
    sleep(CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX);
#endif

    configure_network();

    // TODO: Disable SNTP if no internet connection is available
#if defined(CONFIG_ENABLE_SNTP) && CONFIG_ENABLE_SNTP
    log_info("Setting time using SNTP...\n");
    if (Clock::init_clock_via_sntp() < 0) {
        log_error("Failed to set time using SNTP\n");
        std::exit(1);
    }
#endif

    // Phase 1C lifecycle. Must run AFTER configure_network() so the
    // chosen RMW backend has a routable interface to bind to, and
    // BEFORE `new Controller()` because the Node ctor inside calls
    // nros::create_node() which requires the global runtime to be up.
    log_info("Initializing nano-ros runtime (domain %d)...\n", ASI_DOMAIN_ID);
    {
        auto r = nros::init("", ASI_DOMAIN_ID);
        if (!r.ok()) {
            log_error("nros::init failed: %d\n", r.raw());
            std::exit(1);
        }
    }
    std::atexit([](){ nros::shutdown(); });

    log_info("Starting Controller Node...");
    try
    {
        controller = new autoware::motion::control::trajectory_follower_node::Controller();
        int ret = controller->spin();
        if (ret != 0) {
            log_error("Failed to start Controller Node");
            std::exit(1);
        }
        log_success("Controller Node Started");
        log_success("-----------------------------------------");
    }
    catch(const std::exception& e)
    {
        log_error("Failed to start Controller Node: %s", e.what());
        std::exit(1);
    }

    log_success("Actuation Safety Island is Live");
    log_success("-----------------------------------------");

    controller->wait_for_completion();

    log_info("Actuation Safety Island is Shutting Down");
    log_success("-----------------------------------------");

    return 0;
}
