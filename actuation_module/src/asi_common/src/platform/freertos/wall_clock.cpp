// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Wall clock for the BARE-METAL FreeRTOS lanes (QEMU mps3-an536, NXP S32Z270).
//
// WHY THIS EXISTS. nano-ros's FreeRTOS platform reports no wall clock —
// `nros_platform_time_now_ns()` returns 0 and says so ("no wall-clock source on
// this platform", nano-ros issue 0758) — and newlib's `_gettimeofday` stub
// returns whatever it returns. `Clock::now()` is `std::chrono::system_clock`,
// which lands on that stub, so every control command the island stamped came
// out as garbage. Measured on the an536 lane against a real Autoware:
//
//     stamp: sec: -1749516426  nanosec: 3885855232
//
// A negative second count and a nanosecond field above 1e9. Autoware's
// operation-mode transition manager never published a state with those
// commands on the graph, so autonomous mode could not be engaged and the
// planner sat in "Waiting for operation mode state" forever. The header this
// replaces said as much in a TODO: "On real FreeRTOS hardware (Phase 5), this
// should be replaced with an actual SNTP or NTP client."
//
// SHAPE. An epoch captured from SNTP, plus the platform's MONOTONIC clock for
// everything after: `now = epoch_at_sync + (mono_now - mono_at_sync)`. The
// sync runs on its own low-priority task because an SNTP exchange blocks for
// up to its timeout, which must never happen on the control tier. It repeats,
// for the same reason the Zephyr lane's re-sync exists (see
// common/clock/clock_resync.hpp): a one-shot epoch is unbounded-error by
// construction, since whatever advances it afterwards is not real time.
//
// UNTIL THE FIRST SYNC LANDS the clock reports boot-relative time rather than
// pretending: a peer that checks freshness will reject those commands, which is
// the correct outcome for an island that does not yet know what time it is.
//
// DELIBERATELY NOT peer-derived. Taking the epoch from the newest inbound
// Autoware stamp would need no server and no network code at all — and would
// destroy the freshness gate, because inputs compared against a clock slaved to
// those same inputs can never look stale.

#include <cstdint>
#include <cstring>
#include <ctime>
#include <sys/time.h>

#include "FreeRTOS.h"
#include "task.h"

#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "lwip/sys.h"

#include "common/logger/logger.hpp"

using namespace common::logger;

extern "C" uint64_t nros_platform_clock_ns(void);
extern "C" void asi_start_wall_clock_sync(void);

namespace {

// The demo's unprivileged responder (scripts/sntp-server.py) on the tap host,
// which is this image's gateway. Both overridable at build time.
#ifndef ASI_SNTP_SERVER_IP
#define ASI_SNTP_SERVER_IP "192.0.3.1"
#endif
#ifndef ASI_SNTP_SERVER_PORT
#define ASI_SNTP_SERVER_PORT 12123
#endif
// Re-sync cadence. QEMU's guest clock tracks real time far better than the
// FVP's does, but "better" is not "bounded".
#ifndef ASI_SNTP_RESYNC_INTERVAL_S
#define ASI_SNTP_RESYNC_INTERVAL_S 10
#endif

// How long boot waits for the first epoch, in 100 ms steps. Long enough for a
// couple of 2 s query timeouts, short enough that a demo with no responder
// still reaches its markers instead of looking hung.
constexpr int kBootSyncWaitTicks = 60;

constexpr uint64_t kNsPerSec = 1000000000ULL;
// Seconds between 1900-01-01 (NTP) and 1970-01-01 (Unix).
constexpr uint64_t kNtpEpochOffset = 2208988800ULL;

// Written by the sync task, read by _gettimeofday from any thread. 64-bit
// stores are not atomic on this 32-bit core, so readers re-read the sequence
// around the pair and retry on a torn read (a seqlock, writer side single).
volatile uint32_t g_seq = 0;
uint64_t g_epoch_at_sync_ns = 0;
uint64_t g_mono_at_sync_ns = 0;
volatile bool g_have_epoch = false;

void publish_epoch(uint64_t epoch_ns, uint64_t mono_ns) {
    g_seq++;                       // odd: write in progress
    __asm__ volatile("" ::: "memory");
    g_epoch_at_sync_ns = epoch_ns;
    g_mono_at_sync_ns = mono_ns;
    __asm__ volatile("" ::: "memory");
    g_seq++;                       // even: consistent
    g_have_epoch = true;
}

// Current wall clock in nanoseconds, or 0 when no epoch has been acquired.
uint64_t wall_now_ns() {
    if (!g_have_epoch) {
        return 0;
    }
    uint64_t epoch, mono;
    uint32_t s0, s1;
    do {
        s0 = g_seq;
        epoch = g_epoch_at_sync_ns;
        mono = g_mono_at_sync_ns;
        __asm__ volatile("" ::: "memory");
        s1 = g_seq;
    } while ((s0 & 1u) != 0u || s0 != s1);

    const uint64_t now_mono = nros_platform_clock_ns();
    return epoch + (now_mono > mono ? now_mono - mono : 0);
}

// One SNTP (RFC 4330) exchange. Returns the server's transmit timestamp in
// nanoseconds since the Unix epoch, or 0 on any failure.
uint64_t sntp_query_once() {
    const int fd = lwip_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        return 0;
    }

    struct timeval tv;
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    lwip_setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in srv;
    std::memset(&srv, 0, sizeof(srv));
    srv.sin_family = AF_INET;
    srv.sin_port = lwip_htons(ASI_SNTP_SERVER_PORT);
    srv.sin_addr.s_addr = ipaddr_addr(ASI_SNTP_SERVER_IP);

    // LI=0, VN=4, Mode=3 (client). Everything else zero.
    uint8_t pkt[48];
    std::memset(pkt, 0, sizeof(pkt));
    pkt[0] = 0x23;

    if (lwip_sendto(fd, pkt, sizeof(pkt), 0, reinterpret_cast<struct sockaddr*>(&srv),
                    sizeof(srv)) != static_cast<int>(sizeof(pkt))) {
        lwip_close(fd);
        return 0;
    }

    uint8_t rsp[48];
    const int n = lwip_recv(fd, rsp, sizeof(rsp), 0);
    lwip_close(fd);
    if (n < static_cast<int>(sizeof(rsp))) {
        return 0;
    }

    // Transmit timestamp: seconds at bytes 40..43, fraction at 44..47.
    const uint32_t ntp_sec = (static_cast<uint32_t>(rsp[40]) << 24) |
                             (static_cast<uint32_t>(rsp[41]) << 16) |
                             (static_cast<uint32_t>(rsp[42]) << 8) |
                             static_cast<uint32_t>(rsp[43]);
    const uint32_t ntp_frac = (static_cast<uint32_t>(rsp[44]) << 24) |
                              (static_cast<uint32_t>(rsp[45]) << 16) |
                              (static_cast<uint32_t>(rsp[46]) << 8) |
                              static_cast<uint32_t>(rsp[47]);
    if (ntp_sec <= kNtpEpochOffset) {
        return 0;   // pre-1970: not a usable answer
    }

    const uint64_t unix_sec = static_cast<uint64_t>(ntp_sec) - kNtpEpochOffset;
    const uint64_t frac_ns = (static_cast<uint64_t>(ntp_frac) * kNsPerSec) >> 32;
    return unix_sec * kNsPerSec + frac_ns;
}

void sync_task(void* )  {
#if LWIP_NETCONN_SEM_PER_THREAD
    // This build keeps the netconn completion semaphore in thread-local
    // storage, and the socket layer only ever GETS it — allocation is the
    // thread's own job. Skipping this is "lwIP ASSERT: semaphore not
    // initialized" on the first socket call, which is not a hint about
    // semaphores so much as about who was supposed to make one.
    sys_arch_netconn_sem_alloc();
#endif
    // First query IMMEDIATELY — asi_start_wall_clock_sync() is blocking the
    // node's construction until this lands, so a delay here would be a delay
    // there. Only the re-syncs are on the interval, and every one of those
    // moves the clock by a correction rather than by the initial 56-year step.
    for (;;) {
        const uint64_t epoch_ns = sntp_query_once();
        if (epoch_ns != 0) {
            // Stamp the epoch against the monotonic reading taken just after
            // the reply, so the round trip is not folded into the offset.
            publish_epoch(epoch_ns, nros_platform_clock_ns());
        }
        vTaskDelay(pdMS_TO_TICKS(ASI_SNTP_RESYNC_INTERVAL_S * 1000));
    }
}

}  // namespace

// Newlib routes std::chrono::system_clock here. Our definition is in an object
// file, so it wins over libc's archive stub without needing a weak attribute.
extern "C" int _gettimeofday(struct timeval* tv, void* /*tzvp*/) {
    if (tv == nullptr) {
        return 0;
    }
    uint64_t ns = wall_now_ns();
    if (ns == 0) {
        // No epoch yet — report boot-relative time. Small and positive, so a
        // peer's freshness check rejects it instead of seeing a wild value.
        ns = nros_platform_clock_ns();
    }
    tv->tv_sec = static_cast<time_t>(ns / kNsPerSec);
    tv->tv_usec = static_cast<suseconds_t>((ns % kNsPerSec) / 1000);
    return 0;
}

// Strong override of nano-ros's weak `nros_board_network_wait()`, which
// `nros_board_freertos_run_tiers` calls BEFORE `nros_cpp_init` — the one point
// in boot where the network is up and no DDS entity exists yet.
//
// That timing is the whole reason this lives here. Acquiring the epoch moves
// the clock ~56 years in one step, and CycloneDDS reads the same clock for
// lease deadlines and endpoint bookkeeping; taking the step after the
// participant exists failed create_subscription/create_publisher with
// "rmw_ret error" (code=-100), nondeterministically, depending on which call
// the jump fell across.
//
// It is in THIS translation unit on purpose. The weak default already
// satisfies the reference, so a strong definition sitting alone in the
// component archive is never pulled in — it has to ride a member the link
// already wants, and this one does, via asi_start_wall_clock_sync() below.
extern "C" void nros_board_network_wait(void) {
    log_success("-----------------------------------------");
    log_success("ARM - Autoware: Actuation Safety Island");
    log_success("-----------------------------------------");
    asi_start_wall_clock_sync();
}

extern "C" void asi_start_wall_clock_sync(void) {
    static bool started = false;
    if (started) {
        return;
    }
    started = true;

    // The FIRST sync is SYNCHRONOUS, and that is the whole point of doing it
    // here rather than letting the task get to it.
    //
    // Acquiring the epoch moves this image's wall clock by ~56 years in one
    // step. Cyclone reads the same clock for lease deadlines and endpoint
    // bookkeeping, so when the jump landed mid-construction it failed
    // `create_subscription` / `create_publisher` with "rmw_ret error"
    // (code=-100) — nondeterministically, depending on which call the jump fell
    // across, which is exactly what made it look like a discovery problem.
    // Taking the jump BEFORE the node creates any endpoint removes the window
    // instead of narrowing it.
    //
    // The query itself runs on the sync task, not here: an SNTP exchange
    // through lwIP's socket layer needs several KiB of stack, and running it
    // on the caller's thread overflowed that thread instead (unnamed
    // "*** STACK OVERFLOW ***" right after the epoch landed). So start the
    // task, then WAIT for its first result — the jump still happens before any
    // endpoint exists, without borrowing the caller's stack for it.
    //
    // Bounded wait: if the responder is not there, boot continues with a
    // boot-relative clock rather than hanging. A peer that checks freshness
    // will reject those commands, which is the correct outcome for an island
    // that does not know what time it is.
    // sys_thread_new, NOT xTaskCreate. This lwIP build sets
    // LWIP_NETCONN_SEM_PER_THREAD, so a socket call from a task lwIP never
    // registered dies on "lwIP ASSERT: semaphore not initialized" — which is
    // exactly what a raw xTaskCreate task did here.
    //
    // Priority 2: below the control tier (7) and the transport band — a late
    // sync is harmless, a sync that preempts the control loop is not. The
    // stack argument is BYTES in this port
    // (LWIP_FREERTOS_THREAD_STACKSIZE_IS_STACKWORDS is 0). 16 KiB measured:
    // 4 KiB overflowed on the very first exchange (socket + logging).
    sys_thread_new("asi_sntp", sync_task, nullptr, 16384, 2);

    for (int i = 0; i < kBootSyncWaitTicks && !g_have_epoch; ++i) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (g_have_epoch) {
        log_info("Wall clock set from SNTP\n");
    } else {
        log_error("SNTP sync failed (" ASI_SNTP_SERVER_IP ") — stamps stay boot-relative\n");
    }
}
