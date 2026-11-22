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
// interface configuration (`configure_network()`). The linker prefers this
// strong definition over the weak no-op default.
//
// The wall clock is no longer set here: the image states its source in
// [knobs.clock] (controller_bringup/system.toml), and nano-ros resolves it
// after every component has registered and before anything spins, with the
// retries (clock.sntp_attempts) and the failure policy (clock.epoch_failure,
// `halt` where this hook used to std::exit(1)) it states (phase-15 P5).

#include <unistd.h>

#include "common/logger/logger.hpp"
#include "common/net/network_config.hpp"
using namespace common::logger;

extern "C" void nros_board_network_wait(void)
{
    log_success("-----------------------------------------");
    log_success("ARM - Autoware: Actuation Safety Island");
    log_success("-----------------------------------------");

    // An image that states its network in a board network file (the FVP
    // images) has Zephyr's net_config wait for the lease before the
    // application starts (CONFIG_NET_CONFIG_NEED_IPV4, nano-ros issue 2679);
    // only the others (S32Z) keep this grace.
#if defined(CONFIG_NET_DHCPV4) && CONFIG_NET_DHCPV4 && \
    !defined(CONFIG_NET_CONFIG_NEED_IPV4)
    log_info("Waiting for DHCP to get IP address...");
    sleep(CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX);
#endif

    configure_network();
}
