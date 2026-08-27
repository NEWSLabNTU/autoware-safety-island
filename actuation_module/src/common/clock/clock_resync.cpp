// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Periodic wall-clock re-sync thread. Rationale and the measurements that
// motivated it are in common/clock/clock_resync.hpp.

#if !defined(PLATFORM_ZEPHYR)
#  error "clock_resync.cpp must only be compiled for the Zephyr platform"
#endif

#include <zephyr/kernel.h>

#include "common/clock/clock_resync.hpp"
#include "common/logger/logger.hpp"
#include "platform/platform_clock.h"

using namespace common::logger;

#if defined(CONFIG_ENABLE_SNTP) && CONFIG_ENABLE_SNTP

#ifndef CONFIG_ASI_SNTP_RESYNC_INTERVAL_S
#define CONFIG_ASI_SNTP_RESYNC_INTERVAL_S 10
#endif

// Small stack: the thread owns no application state and calls sntp_simple()
// plus clock_settime(), both of which the boot path already exercises on the
// (larger) network-hook stack.
// Was a hardcoded 4096, measured 100 % consumed (unused 0) under load — see
// CONFIG_ASI_SNTP_RESYNC_STACK_SIZE. sntp_simple() blocks and does socket work.
#define RESYNC_STACK_SIZE CONFIG_ASI_SNTP_RESYNC_STACK_SIZE
// Below every application tier and below the transport band: a late re-sync is
// harmless, a re-sync that preempts the control tier is not.
#define RESYNC_PRIORITY   K_LOWEST_APPLICATION_THREAD_PRIO

static K_THREAD_STACK_DEFINE(resync_stack, RESYNC_STACK_SIZE);
static struct k_thread resync_thread_data;
static bool resync_started;

// Report a correction only when it is big enough to matter, so a healthy
// island stays quiet while a drifting one is loud. The threshold is well under
// the sub-second ages peers compute from our stamps.
static constexpr double REPORT_CORRECTION_S = 0.25;

static void resync_thread(void *, void *, void *)
{
    // Sleeps in KERNEL time on purpose: when the guest clock races (the FVP
    // fast-forwards an idle guest), the same interval elapses sooner in real
    // time, so re-syncs land more often exactly when drift is worst.
    const k_timeout_t interval = K_SECONDS(CONFIG_ASI_SNTP_RESYNC_INTERVAL_S);

    for (;;) {
        k_sleep(interval);

        double correction_s = 0.0;
        const int res = platform_sync_clock_via_sntp(&correction_s);
        if (res < 0) {
            // Throttled: an unreachable server must not turn into a log flood,
            // and the clock simply keeps its previous epoch.
            log_warn_throttle("SNTP re-sync failed (%d); keeping the current epoch", res);
            continue;
        }

        const double magnitude = correction_s < 0.0 ? -correction_s : correction_s;
        if (magnitude >= REPORT_CORRECTION_S) {
            log_info("SNTP re-sync stepped the clock by %+.3f s", correction_s);
        } else {
            log_debug("SNTP re-sync: %+.6f s", correction_s);
        }
    }
}

extern "C" void asi_start_clock_resync(void)
{
    if (CONFIG_ASI_SNTP_RESYNC_INTERVAL_S <= 0) {
        log_info("SNTP re-sync disabled (interval 0) — stamps drift with the platform tick");
        return;
    }
    if (resync_started) {
        return;
    }
    resync_started = true;

    k_thread_create(&resync_thread_data, resync_stack, RESYNC_STACK_SIZE,
                    resync_thread, nullptr, nullptr, nullptr,
                    RESYNC_PRIORITY, 0, K_NO_WAIT);
    k_thread_name_set(&resync_thread_data, "asi_sntp_resync");
    log_info("SNTP re-sync every %d s", (int)CONFIG_ASI_SNTP_RESYNC_INTERVAL_S);
}

#else  // !CONFIG_ENABLE_SNTP

extern "C" void asi_start_clock_resync(void)
{
    // No epoch source configured: nothing to re-sync. The island stamps from
    // its boot epoch, which is the documented no-SNTP behaviour.
}

#endif  // CONFIG_ENABLE_SNTP
