// Copyright (c) 2024-2026, Arm Limited / NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 2.C / 242.5 — strong override of nano-ros's weak
// `nros_board_network_wait()` hook (declared in <nros/main.hpp>). The generated
// Zephyr Entry's `nros::board::ZephyrBoard::run_components` calls this BEFORE
// `nros::init`, so the chosen RMW backend has a routable interface to bind to.
//
// This is the network-readiness prologue that used to live at the top of the
// retired imperative `src/main.cpp`: the DHCP initial-delay grace, ASI's static
// interface configuration (`configure_network()`), and the optional SNTP clock
// sync. The linker prefers this strong definition over the weak no-op default.

#include <cstdlib>
#include <unistd.h>

#include "common/clock/clock.hpp"
#include "common/clock/clock_resync.hpp"
#include "common/logger/logger.hpp"
#include "common/net/network_config.hpp"
using namespace common::logger;

extern "C" void nros_board_network_wait(void)
{
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
    // The boot epoch alone is not enough: whatever advances it afterwards is
    // never exactly real time (on FVP, ~10.5x while idle), and every command we
    // stamp inherits that error. Keep it bounded — see common/clock/clock_resync.hpp.
    asi_start_clock_resync();
#endif
}
