// Copyright (c) 2025, Arm Limited.
// SPDX-License-Identifier: Apache-2.0

#ifndef PLATFORM__ZEPHYR__CLOCK_H_
#define PLATFORM__ZEPHYR__CLOCK_H_

#include <zephyr/posix/time.h>
#include <zephyr/net/sntp.h>
#include <cstdint>
#include <ctime>
#include <cstdio>
#include "common/logger/logger.hpp"

#ifndef CONFIG_SNTP_SERVER_ADDRESS
#define CONFIG_SNTP_SERVER_ADDRESS "time.nist.gov"
#endif

// Query SNTP and step CLOCK_REALTIME. `correction_s`, when non-null, receives
// the size of the step (new epoch minus the clock we were carrying) — the
// re-sync thread reports it so drift is visible rather than silent.
//
// Split out of platform_init_clock_via_sntp() so the periodic re-sync can call
// it without the boot path's banner logging and settling sleep (see
// common/clock/clock_resync.hpp: a one-shot epoch is unbounded-error, because
// whatever advances it afterwards — on FVP a fast-forwarded idle guest, on
// silicon an oscillator — is never exactly real time).
// Timeout is in GUEST milliseconds, and on the FVP the guest clock races the
// host (~10.5x while idle — the very drift the re-sync exists to correct). At
// 10 s guest the wait expired after roughly ONE second of real time, before the
// responder's reply could arrive; `sntp_simple` then closed its socket, the
// reply landed on a freed net_context, and Zephyr's
// `NET_ASSERT(context)` in net_context_packet_received() panicked the kernel
// on the rx_q thread — a boot that never reached "Actuation Safety Island is
// Live". 60 s guest is ~6 s real here, comfortably longer than the round trip,
// and still bounded. The re-sync thread is the lowest priority in the image,
// so waiting longer costs nothing.
static inline int platform_sync_clock_via_sntp(double * correction_s) {
    struct sntp_time ts;
    struct timespec tspec;
    int res = sntp_simple(CONFIG_SNTP_SERVER_ADDRESS, 60000, &ts);

    if (res < 0) {
        return res;
    }

    tspec.tv_sec = ts.seconds;
    tspec.tv_nsec = ((uint64_t)ts.fraction * (1000 * 1000 * 1000)) >> 32;

    if (correction_s != nullptr) {
        struct timespec before;
        if (clock_gettime(CLOCK_REALTIME, &before) == 0) {
            *correction_s = ((double)tspec.tv_sec - (double)before.tv_sec)
                          + ((double)tspec.tv_nsec - (double)before.tv_nsec) * 1e-9;
        } else {
            *correction_s = 0.0;
        }
    }

    res = clock_settime(CLOCK_REALTIME, &tspec);
    if (res < 0) {
        return res;
    }
    return 0;
}

static inline int platform_init_clock_via_sntp(void) {
    int res = platform_sync_clock_via_sntp(nullptr);
    if (res < 0) {
        common::logger::log_error("Cannot set time using SNTP\n");
        return res;
    }

    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    sleep(1);
    common::logger::log_info("Time set using SNTP: %s\n", ctime(&now.tv_sec));
    return 0;
}

#endif  // PLATFORM__ZEPHYR__CLOCK_H_
