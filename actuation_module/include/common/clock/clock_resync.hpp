// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Periodic wall-clock re-sync.
//
// WHY THIS EXISTS. A one-shot epoch is unbounded-error by construction: SNTP
// sets CLOCK_REALTIME once at boot, and from then on the epoch is advanced by
// whatever the platform's tick happens to be. On real silicon that is an
// oscillator (ppm-level, so hours of drift are still small); on the FVP the
// model FAST-FORWARDS an idle guest, and the island's wall-clock estimate was
// measured advancing ~10.5x real time — 3694 s of offset, growing 160 s per
// 16 s of host wall clock, with no bound.
//
// That is not a cosmetic problem. The island STAMPS every control command with
// this clock, and peers compute ages from those stamps. Autoware's
// `mrm_emergency_stop_operator` seeds its braking ramp over an unclamped
// `now - input.stamp`; handed a stamp 2376 s in the future it produced
// a = +7127 m/s^2 — an emergency stop turned into maximum acceleration (the
// missing clamp is the peer's own defect; the drifting stamp was ours). Full
// record: docs/roadmap/phase-4, "MRM divergence — investigated and root-caused".
//
// The upstream design requirement — an epoch hook must be RE-callable, not
// one-shot — is filed as nano-ros issue 0758; when nano-ros grows a platform
// epoch source this file is what it replaces.
//
// SHAPE. A dedicated low-priority thread, not a timer callback and not a work
// item: `sntp_simple()` blocks for up to its timeout, which must never happen
// on the executor thread that runs the control tier or on the system work
// queue. It sleeps in KERNEL time, which is the self-correcting choice — when
// the guest clock races, re-syncs land more often in real time.

#ifndef COMMON__CLOCK__CLOCK_RESYNC_HPP_
#define COMMON__CLOCK__CLOCK_RESYNC_HPP_

// Start the periodic re-sync. Safe to call once, after the boot-time epoch has
// been acquired; a no-op on platforms without SNTP and when the interval is
// configured to 0. Never fails the boot — a re-sync that cannot reach its
// server leaves the clock where it was and says so, throttled.
extern "C" void asi_start_clock_resync(void);

#endif  // COMMON__CLOCK__CLOCK_RESYNC_HPP_
