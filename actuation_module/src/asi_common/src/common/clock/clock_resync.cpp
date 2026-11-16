// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Periodic wall-clock re-sync thread. Rationale and the measurements that
// motivated it are in common/clock/clock_resync.hpp.

#if !defined(PLATFORM_ZEPHYR)
#  error "clock_resync.cpp must only be compiled for the Zephyr platform"
#endif

#include <zephyr/kernel.h>

#include <time.h>   // clock_gettime — the loop paces on CLOCK_REALTIME

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
    // Paced by the CORRECTED WALL CLOCK, not by kernel time.
    //
    // This used to sleep in kernel time, on the theory that a racing guest
    // clock would then re-sync more often in real time — "more often exactly
    // when drift is worst". At FVP magnitudes that reasoning inverts: the
    // guest fast-forwards so hard that a 10 s kernel sleep is ~0.1 s of real
    // time, so the loop became a spin. Measured on the tap lane: 6184 re-syncs
    // in nine real minutes (~11/s), each one stepping the clock back ~10 s,
    // and the boot thread never got far enough to print
    // "Actuation Safety Island is Live".
    //
    // CLOCK_REALTIME is the one clock here that tracks real time, because SNTP
    // keeps correcting it. Pacing on it gives a real interval on any guest, and
    // costs nothing on silicon where the two agree.
    const double interval_s = (double)CONFIG_ASI_SNTP_RESYNC_INTERVAL_S;
    // Kernel-time granularity of the wait. Small enough to stay responsive,
    // large enough that a racing guest does not spin through it.
    const k_timeout_t poll = K_MSEC(200);

    for (;;) {
        struct timespec start;
        clock_gettime(CLOCK_REALTIME, &start);
        for (;;) {
            k_sleep(poll);
            struct timespec now;
            clock_gettime(CLOCK_REALTIME, &now);
            const double elapsed = (double)(now.tv_sec - start.tv_sec) +
                                   (double)(now.tv_nsec - start.tv_nsec) / 1e9;
            // A re-sync that steps the clock BACKWARD makes `elapsed` go
            // negative; treat that as "wait the full interval again" rather
            // than looping forever on a moving start point.
            if (elapsed >= interval_s || elapsed < 0.0) {
                break;
            }
        }

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
