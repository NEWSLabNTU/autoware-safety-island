#ifndef COMMON__LOGGER_LOGGER_HPP_
#define COMMON__LOGGER_LOGGER_HPP_

// Phase 5 W5 — one logging spine: the `log_*` API surface stays (20+
// vendored Autoware TUs call it), but the sink is nano-ros's `nros_log`
// dispatcher (`rclc_log_emit_fmt` through the per-platform writer chain:
// POSIX stderr / Zephyr LOG / board fn-ptr on the FreeRTOS family). The
// old ASI-local implementation (colors, HH:MM:SS.mmm prefix, stderr) is
// gone — timestamps/format now come from the platform sink.
//
// Throttled lines are nano-ros's `RCLCPP_*_THROTTLE(logger, clock, ms, ...)`
// at the call site (upstream's macro, measured on the clock argument), not
// a helper here.
//
// Kept ASI-side (upstream has no equivalents yet):
//   * CONFIG_LOG_LEVEL compile-time gating -- zero-cost below level; the
//     nros per-logger runtime threshold defaults to INFO, so `log_debug`/
//     PROFILE emit at INFO severity and ASI's compile-time gate stays the
//     debug on/off switch.

#include <chrono>
#include <cstdio>
#include <cstdarg>
#include "platform/platform_config.h"

#include <rclc/log.h>

namespace common::logger {

// Lazy, idempotent sink bring-up. Hosted POSIX wires the dispatcher from
// .init_array; the no_std lanes (FreeRTOS/S32Z2) need the explicit
// `rclc_log_init()` after the board's platform-log writer registers —
// calling it from a magic static covers both (idempotent upstream).
inline rclc_logger_t default_logger_() {
    static const bool init_once = (rclc_log_init(), true);
    (void)init_once;
    return rclc_log_default_logger();
}

inline void vemit_(rcl_log_severity_t severity, const char * format, va_list args) {
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    // Callers historically embed a trailing '\n'; the sink adds its own
    // line ending, so strip one trailing newline to avoid blank lines.
    size_t len = 0;
    while (buffer[len] != '\0') { ++len; }
    if (len > 0 && buffer[len - 1] == '\n') { buffer[len - 1] = '\0'; }
    rclc_log_emit_fmt(default_logger_(), severity, "%s", buffer);
}

inline void log_success(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(RCLC_LOG_SEVERITY_INFO, format, args);
    va_end(args);
    #endif
}

inline void log_info(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(RCLC_LOG_SEVERITY_INFO, format, args);
    va_end(args);
    #endif
}

inline void log_warn(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(RCLC_LOG_SEVERITY_WARN, format, args);
    va_end(args);
    #endif
}

inline void log_error(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(RCLC_LOG_SEVERITY_ERROR, format, args);
    va_end(args);
    #endif
}

inline void log_debug(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 2
    va_list args;
    va_start(args, format);
    // INFO severity on purpose: the nros default threshold is INFO with no
    // C-side setter; ASI's compile-time gate is the debug switch.
    vemit_(RCLC_LOG_SEVERITY_INFO, format, args);
    va_end(args);
    #endif
}

} // namespace common::logger

// --- Per-cycle profiling instrumentation ------------------------------------
// Compiled out entirely unless CONFIG_LOG_LEVEL >= 2 (debug): the default INFO
// build takes no timestamps and evaluates none of the log arguments, so the
// instrumentation adds zero latency/jitter to the control cycle it measures.
// Uses a monotonic clock (steady_clock) so an SNTP step cannot produce negative
// or garbled deltas. PROFILE_MS returns milliseconds as a double.
#if CONFIG_LOG_LEVEL >= 2
#define PROFILE_POINT(name) const auto name = std::chrono::steady_clock::now()
#define PROFILE_MS(from, to) \
    (std::chrono::duration<double, std::milli>((to) - (from)).count())
#define PROFILE_LOG(...) common::logger::log_debug(__VA_ARGS__)
#else
#define PROFILE_POINT(name) ((void)0)
#define PROFILE_MS(from, to) 0.0
#define PROFILE_LOG(...) ((void)0)
#endif

#endif  // COMMON__LOGGER_LOGGER_HPP_
