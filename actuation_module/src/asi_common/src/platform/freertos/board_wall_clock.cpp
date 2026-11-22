// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// The board wall-clock source of the BARE-METAL FreeRTOS images (QEMU
// mps3-an536, NXP S32Z270): nano-ros's `board` hook over the island's own
// SNTP task (nano-ros RFC-0141 D2, phase-582 W1d; ASI phase-15 P5).
//
// WHY THE ISLAND. nano-ros has no SNTP client on lwIP, and a bare-metal
// FreeRTOS image has no clock of its own, so its `platform` source never
// answers. The images state `[knobs.clock] source = "board"`
// (controller_bringup/system.toml), and nano-ros asks this hook. Everything
// else is nano-ros's: newlib's gettimeofday, libstdc++'s system_clock and
// rclcpp's RCL_SYSTEM_TIME all read the offset it installs, and nothing here
// defines `_gettimeofday`.
//
// THE CONTRACT. nano-ros resolves the source lazily, on the first wall-clock
// read from a running task. While nothing is latched it asks
// `nros_board_wall_clock_ns` every 10 ms for up to clock.fallback_settle_ms;
// the first `true` installs `board - monotonic` and latches it, and the hook
// is never asked again. A window that runs out goes to clock.epoch_failure.
// So the hook must be cheap and must not block: it answers from what the
// SNTP task last published, and `false` until that task has an epoch.
//
// THE TASK. The first ask starts it (nothing else here runs in an image that
// does not select `board`, such as the test programs). It waits for lwIP's
// default netif to be up, queries the image's gateway (the demo's
// scripts/sntp-server.py on the tap host; QEMU's user network forwards it to
// the host's loopback), and retries every second until it has an epoch. It
// ends itself once it has one, or once nano-ros has stopped asking (the
// window ran out), so it costs its 16 KiB stack only during boot.
//
// The jump that used to break Cyclone (a ~56-year step taken after the
// participant existed: create_* failed with rmw_ret -100) cannot happen: the
// first read that resolves the clock is the first read of it, and it waits
// for the verdict.
//
// DELIBERATELY NOT peer-derived. Taking the epoch from the newest inbound
// Autoware stamp needs no server, and would destroy the freshness gate:
// inputs compared against a clock slaved to those same inputs never look
// stale.

#include <cstdint>
#include <cstring>

#include "FreeRTOS.h"
#include "task.h"

#include "lwip/inet.h"
#include "lwip/netif.h"
#include "lwip/sockets.h"
#include "lwip/sys.h"

extern "C" uint64_t nros_platform_clock_ns(void);
extern "C" bool nros_board_wall_clock_ns(uint64_t* out_ns);

namespace {

// The server. Unset, it is the image's gateway; a deployment states its own
// address at build time. The port is the demo responder's unprivileged one.
#ifndef ASI_SNTP_SERVER_PORT
#define ASI_SNTP_SERVER_PORT 12123
#endif

constexpr uint64_t kNsPerSec = 1000000000ULL;
// Seconds between 1900-01-01 (NTP) and 1970-01-01 (Unix).
constexpr uint64_t kNtpEpochOffset = 2208988800ULL;
// How long the task keeps querying after the hook was last asked: nano-ros
// asks every 10 ms while it waits, so a second of silence means it resolved.
constexpr uint64_t kAskedRecentlyNs = kNsPerSec;

// Written by the task once, read by the hook. 64-bit stores are not atomic on
// this 32-bit core: the hook reads `g_have_epoch` (release/acquire) before the
// pair, which the task never writes again.
uint64_t g_epoch_at_sync_ns = 0;
uint64_t g_mono_at_sync_ns = 0;
bool g_have_epoch = false;
// The monotonic instant of the last ask, for the task's exit.
uint64_t g_last_ask_ns = 0;
bool g_started = false;

void note_ask(uint64_t mono_ns) {
    __atomic_store_n(&g_last_ask_ns, mono_ns, __ATOMIC_RELAXED);
}

bool still_asked(uint64_t mono_ns) {
    return mono_ns - __atomic_load_n(&g_last_ask_ns, __ATOMIC_RELAXED) < kAskedRecentlyNs;
}

// The server's IPv4 address, network order, or 0 when there is none yet.
uint32_t server_addr() {
#ifdef ASI_SNTP_SERVER_IP
    return ipaddr_addr(ASI_SNTP_SERVER_IP);
#else
    struct netif* nif = netif_default;
    if (nif == nullptr || !netif_is_up(nif)) {
        return 0;
    }
    return ip4_addr_get_u32(netif_ip4_gw(nif));
#endif
}

// One SNTP (RFC 4330) exchange. Returns the server's transmit timestamp in
// nanoseconds since the Unix epoch, or 0 on any failure.
uint64_t sntp_query_once(uint32_t addr) {
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
    srv.sin_addr.s_addr = addr;

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

void sync_task(void*) {
#if LWIP_NETCONN_SEM_PER_THREAD
    // This lwIP build keeps the netconn completion semaphore per thread, and
    // allocating it is the thread's own job: without it the first socket call
    // is "lwIP ASSERT: semaphore not initialized".
    sys_arch_netconn_sem_alloc();
#endif
    for (;;) {
        const uint32_t addr = server_addr();
        if (addr != 0) {
            const uint64_t epoch_ns = sntp_query_once(addr);
            if (epoch_ns != 0) {
                // Paired with the monotonic reading taken just after the
                // reply, so the round trip is not folded into the offset.
                g_epoch_at_sync_ns = epoch_ns;
                g_mono_at_sync_ns = nros_platform_clock_ns();
                __atomic_store_n(&g_have_epoch, true, __ATOMIC_RELEASE);
                break;
            }
        }
        if (!still_asked(nros_platform_clock_ns())) {
            break;   // nano-ros resolved without us (the window ran out)
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
#if LWIP_NETCONN_SEM_PER_THREAD
    sys_arch_netconn_sem_free();
#endif
    vTaskDelete(nullptr);
}

void start_sync_task() {
    // One resolver asks at a time (nano-ros claims the resolution under the
    // port's critical section), so a plain flag suffices.
    if (g_started) {
        return;
    }
    g_started = true;
    // sys_thread_new, not xTaskCreate: a socket call from a task lwIP did not
    // create has no netconn semaphore in this build. Priority 2: below the
    // control tier and the transport band; a late sync is harmless, one that
    // preempts the control loop is not. The stack is BYTES in this port
    // (LWIP_FREERTOS_THREAD_STACKSIZE_IS_STACKWORDS 0); 16 KiB measured, 4 KiB
    // overflowed on the first exchange.
    sys_thread_new("asi_sntp", sync_task, nullptr, 16384, 2);
}

}  // namespace

// nano-ros's `board` wall-clock hook: true with the Unix time in *out_ns once
// the SNTP task has an epoch, false before. Never blocks.
extern "C" bool nros_board_wall_clock_ns(uint64_t* out_ns) {
    const uint64_t now_mono = nros_platform_clock_ns();
    note_ask(now_mono);
    if (!__atomic_load_n(&g_have_epoch, __ATOMIC_ACQUIRE)) {
        start_sync_task();
        return false;
    }
    if (out_ns == nullptr) {
        return false;
    }
    *out_ns = g_epoch_at_sync_ns +
              (now_mono > g_mono_at_sync_ns ? now_mono - g_mono_at_sync_ns : 0);
    return true;
}
