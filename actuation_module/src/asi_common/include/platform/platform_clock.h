// Copyright (c) 2025, Arm Limited.
// SPDX-License-Identifier: Apache-2.0

#ifndef PLATFORM__CLOCK_H_
#define PLATFORM__CLOCK_H_

// The FreeRTOS backend provides:
//   static int platform_init_clock_via_sntp(void);
//   static int platform_sync_clock_via_sntp(double * correction_s);
//
// Zephyr provides nothing here: its images take the wall clock from
// nano-ros's [knobs.clock] source (common/clock/clock.hpp), and the island
// no longer runs SNTP itself there (phase-15 P5).

#if defined(PLATFORM_ZEPHYR)
  #error "platform_clock.h has no Zephyr backend: the wall clock is nano-ros's [knobs.clock] source"
#elif defined(PLATFORM_FREERTOS)
  #include "platform/freertos/freertos_clock.h"
#else
  #error "No platform defined. Define PLATFORM_ZEPHYR or PLATFORM_FREERTOS."
#endif

#endif  // PLATFORM__CLOCK_H_
