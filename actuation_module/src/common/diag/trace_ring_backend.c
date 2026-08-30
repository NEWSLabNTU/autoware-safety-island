/*
 * Copyright (c) 2026, Arm Limited.
 * SPDX-License-Identifier: Apache-2.0
 *
 * phase-8 W8 — an overwrite-oldest tracing backend, for use as a flight
 * recorder.
 *
 * Zephyr ships CONFIG_TRACING_BACKEND_RAM, and it is FILL-ONCE, not a ring:
 *
 *     if (buffer_full) { return; }
 *     if ((pos + length) > CONFIG_RAM_TRACING_BUFFER_SIZE) {
 *             buffer_full = true; return;
 *     }
 *
 * It captures the first N bytes and then goes silent permanently. Cheap once
 * full, and useless, which is exactly the wrong trade for a recorder meant to
 * explain a fault that just happened: the interesting events are the LAST
 * ones, and those are precisely the ones it drops.
 *
 * This backend keeps the last N bytes instead.
 *
 * FRAMING. Zephyr's CTF stream has no packet header — it is a bare sequence of
 * events — so a ring of raw bytes cannot be decoded from an arbitrary start:
 * nothing says where an event begins. Each record is therefore stored
 * length-prefixed, and `tail` is advanced past WHOLE records before a write
 * clobbers them, so the ring always holds complete events. In sync mode each
 * `output()` call carries exactly one event (tracing_format_sync.c calls
 * tracing_buffer_handle once, under TRACING_LOCK), which is what makes that
 * framing exact rather than approximate.
 *
 * The dump then linearises oldest-first, so what leaves the device is an
 * ordinary CTF stream that scripts/parse-zephyr-ctf.py reads with no changes.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <string.h>
#include <tracing_backend.h>

#define RING_SIZE CONFIG_ASI_TRACE_RING_SIZE
#define HDR_BYTES 2u   /* uint16 length prefix */

/* `.noinit` so a warm reset does not clear the evidence — the case a flight
 * recorder exists for. Zeroing happens explicitly in init() instead.
 */
static uint8_t ring[RING_SIZE] __attribute__((section(".noinit")));
static uint32_t head;      /* next write offset */
static uint32_t tail;      /* oldest whole record */
static uint32_t stored;    /* bytes currently held, including prefixes */
static uint32_t dropped;   /* records evicted to make room */

static inline uint32_t ring_rd8(uint32_t off) { return ring[off % RING_SIZE]; }

static void ring_write(const uint8_t *src, uint32_t n)
{
	for (uint32_t i = 0; i < n; i++) {
		ring[(head + i) % RING_SIZE] = src[i];
	}
	head = (head + n) % RING_SIZE;
}

/* Advance `tail` past whole records until `need` bytes are free. Evicting a
 * PARTIAL record would leave a length prefix pointing into the middle of the
 * next one, and the dump would emit garbage that still looks like CTF.
 */
static void ring_evict(uint32_t need)
{
	while (stored + need > RING_SIZE) {
		uint32_t len = ring_rd8(tail) | (ring_rd8(tail + 1) << 8);
		uint32_t rec = HDR_BYTES + len;

		if (rec > stored) {        /* corrupt: drop everything */
			tail = head;
			stored = 0;
			return;
		}
		tail = (tail + rec) % RING_SIZE;
		stored -= rec;
		dropped++;
	}
}

static void asi_ring_output(const struct tracing_backend *backend,
			    uint8_t *data, uint32_t length)
{
	ARG_UNUSED(backend);

	/* A record that cannot fit even in an empty ring is dropped whole
	 * rather than truncated: half an event decodes as a plausible
	 * different event, which is worse than a gap the decoder can count.
	 */
	if (length + HDR_BYTES > RING_SIZE) {
		dropped++;
		return;
	}

	ring_evict(length + HDR_BYTES);

	uint8_t hdr[HDR_BYTES] = { (uint8_t)(length & 0xff),
				   (uint8_t)((length >> 8) & 0xff) };
	ring_write(hdr, HDR_BYTES);
	ring_write(data, length);
	stored += HDR_BYTES + length;
}

static void asi_ring_init(void)
{
	head = tail = stored = dropped = 0;
	memset(ring, 0, RING_SIZE);
}

const struct tracing_backend_api asi_trace_ring_api = {
	.init = asi_ring_init,
	.output = asi_ring_output,
};

TRACING_BACKEND_DEFINE(asi_trace_ring, asi_trace_ring_api);

/* ---- Dump ------------------------------------------------------------- */

static const struct device *const dump_uart =
	DEVICE_DT_GET(DT_CHOSEN(zephyr_tracing_uart));

/**
 * Emit the retained events oldest-first as an ordinary CTF stream.
 *
 * Writes to the same UART the UART backend would have used, so an existing
 * capture pipeline needs no changes -- what lands in the file is a linear
 * stream, not a ring image.
 *
 * Tracing is stopped for the duration. Emitting takes far longer than an
 * event, so letting the ring mutate underneath the walk would interleave new
 * records into the middle of old ones.
 */
void asi_trace_ring_dump(void)
{
	if (!device_is_ready(dump_uart)) {
		printk("asi: trace ring: dump uart not ready\n");
		return;
	}

	unsigned int key = irq_lock();
	uint32_t at = tail, left = stored, records = 0;

	while (left >= HDR_BYTES) {
		uint32_t len = ring_rd8(at) | (ring_rd8(at + 1) << 8);

		if (HDR_BYTES + len > left) {
			break;             /* truncated tail; stop cleanly */
		}
		at = (at + HDR_BYTES) % RING_SIZE;
		for (uint32_t i = 0; i < len; i++) {
			uart_poll_out(dump_uart, ring[(at + i) % RING_SIZE]);
		}
		at = (at + len) % RING_SIZE;
		left -= HDR_BYTES + len;
		records++;
	}
	irq_unlock(key);

	printk("asi: trace ring: dumped %u records, %u bytes retained, "
	       "%u evicted\n", records, stored, dropped);
}

/* ---- Optional self-triggered dump ------------------------------------- */

#if CONFIG_ASI_TRACE_RING_AUTODUMP_S > 0
/* A recorder nobody reads is not a recorder. On a real fault the dump belongs
 * in a fatal-error hook; this timed variant exists so the ring can be
 * exercised end to end -- let it wrap, dump, decode -- without a debugger and
 * without an artificial crash.
 *
 * Lowest priority: emitting is a long poll-out loop and must never preempt
 * the work being recorded.
 */
static void asi_trace_ring_autodump(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	k_sleep(K_SECONDS(CONFIG_ASI_TRACE_RING_AUTODUMP_S));
	asi_trace_ring_dump();
}

K_THREAD_DEFINE(asi_trace_ring_dumper, 2048, asi_trace_ring_autodump,
		NULL, NULL, NULL, K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);
#endif
