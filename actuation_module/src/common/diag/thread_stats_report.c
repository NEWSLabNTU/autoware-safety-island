/*
 * Copyright (c) 2026, Arm Limited.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Periodic thread-statistics reporter for the real-time evaluation profile
 * (docs/design/rt_evaluation_zephyr.rst, Layer 1).
 *
 * This exists because Zephyr's own CONFIG_THREAD_ANALYZER_AUTO cannot be used
 * here. Its worker is
 *
 *     for (;;) { thread_analyzer_print(); k_sleep(K_SECONDS(INTERVAL)); }
 *
 * behind a K_THREAD_DEFINE with a ZERO start delay, so the first dump always
 * runs during boot no matter how the interval is set. On this application that
 * dump -- which walks every thread and printks a block each -- pushes network
 * initialisation past an internal timeout: the DDS loopback test fails with
 * `nros::init failed: -100`, where the identical image without the analyzer
 * passes in 12.187 s. Intervals of 5 s and 20 s fail identically, which is the
 * signature that the interval is not what matters. Filed upstream; see
 * docs/design/upstream-zephyr-issues.md issue 3.
 *
 * The fix is the start delay upstream lacks. CONFIG_THREAD_ANALYZER stays on
 * (it provides thread_analyzer_print()), CONFIG_THREAD_ANALYZER_AUTO stays off,
 * and this thread does the printing after init has settled.
 *
 * Self-registering: K_THREAD_DEFINE needs no call from main() or from any test,
 * so the controller image and every test program get the same reporting with no
 * shared entry point to modify.
 */

#include <zephyr/kernel.h>
#include <zephyr/debug/thread_analyzer.h>

/* Low enough that reporting never preempts real work; the analyzer walks the
 * thread list and printks, which is not something to do at an interesting
 * priority.
 */
#define ASI_THREAD_STATS_PRIO K_LOWEST_APPLICATION_THREAD_PRIO

static void asi_thread_stats_fn(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	unsigned int emitted = 0;

	for (;;) {
		/* Sleep FIRST. Combined with the start delay below this is
		 * belt-and-braces: even if the delay were ever set to 0, no
		 * dump would land during initialisation.
		 */
		k_sleep(K_SECONDS(CONFIG_ASI_THREAD_STATS_INTERVAL));
		thread_analyzer_print();

		/* Bound the output. Under the FVP the model fast-forwards
		 * through WFI, so once the workload finishes and everything
		 * idles, guest time races ahead of host time -- an uncapped
		 * reporter emitted 2000 blocks (104k lines) in a 130 s host
		 * run, which is unusable as a CI artifact. Zero means no cap.
		 */
		emitted++;
		if (CONFIG_ASI_THREAD_STATS_MAX_REPORTS != 0 &&
		    emitted >= CONFIG_ASI_THREAD_STATS_MAX_REPORTS) {
			return;
		}
	}
}

K_THREAD_DEFINE(asi_thread_stats,
		CONFIG_ASI_THREAD_STATS_STACK_SIZE,
		asi_thread_stats_fn,
		NULL, NULL, NULL,
		ASI_THREAD_STATS_PRIO,
		0,
		CONFIG_ASI_THREAD_STATS_START_DELAY * 1000);
