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
// The level gate is nano-ros's compile-time floor, RCLC_LOG_MIN_SEVERITY
// (<rclc/log.h>, 0 trace .. 6 none, numbered as the image's log.max_level),
// which asi_common's CMakeLists.txt sets for every user of asi_common (INFO
// unless the image asks for another level). `log_*` and `PROFILE_LOG` are
// macros, so a call below the floor expands to `((void)0)` and evaluates
// none of its arguments. `log_success` is INFO: rclc has no success level.
// Call them unqualified (`log_info(...)`, not `common::logger::log_info`).

#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>

// asi_common's interface defines the floor; a TU that reaches this header
// without linking asi_common would get <rclc/log.h>'s default, TRACE.
#ifndef RCLC_LOG_MIN_SEVERITY
#error "RCLC_LOG_MIN_SEVERITY is unset: link asi_common, which sets the island's log floor"
#endif
#include <rclc/log.h>

namespace common::logger {

// Lazy, idempotent sink bring-up. Hosted POSIX wires the dispatcher from
// .init_array; the no_std lanes (FreeRTOS/S32Z2) need the explicit
// `rclc_log_init()` after the board's platform-log writer registers —
// calling it from a magic static covers both (idempotent upstream).
//
// A floor of exactly DEBUG (log.max_level = 1) is the debug build: the
// default logger's run-time threshold (INFO unless set) is lowered to DEBUG
// as well, so `log_debug` lines are shown and not only compiled in.
inline rclc_logger_t default_logger_() {
    static const rclc_logger_t logger = [] {
        rclc_log_init();
        rclc_logger_t l = rclc_log_default_logger();
#if RCLC_LOG_MIN_SEVERITY == RCLC_LOG_MIN_SEVERITY_DEBUG
        rclc_logger_set_level(l, RCLC_LOG_SEVERITY_DEBUG);
#endif
        return l;
    }();
    return logger;
}

// The emit behind every macro below. Callers historically embed a trailing
// '\n'; the sink adds its own line ending, so one trailing newline is
// stripped to avoid blank lines. The record is then bounded by
// rclc_log_emit_fmt's own buffer (NROS_LOG_FMT_BUFFER_SIZE), as before.
inline void emit_(rcl_log_severity_t severity, const char * format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    const size_t len = std::strlen(buffer);
    if (len > 0 && buffer[len - 1] == '\n') { buffer[len - 1] = '\0'; }
    rclc_log_emit_fmt(default_logger_(), severity, "%s", buffer);
}

} // namespace common::logger

#define ASI_LOG_COMPILED_OUT_() ((void)0)

#if RCLC_LOG_MIN_SEVERITY <= RCLC_LOG_MIN_SEVERITY_DEBUG
#define log_debug(...) ::common::logger::emit_(RCLC_LOG_SEVERITY_DEBUG, __VA_ARGS__)
#else
#define log_debug(...) ASI_LOG_COMPILED_OUT_()
#endif

#if RCLC_LOG_MIN_SEVERITY <= RCLC_LOG_MIN_SEVERITY_INFO
#define log_info(...) ::common::logger::emit_(RCLC_LOG_SEVERITY_INFO, __VA_ARGS__)
#define log_success(...) ::common::logger::emit_(RCLC_LOG_SEVERITY_INFO, __VA_ARGS__)
#else
#define log_info(...) ASI_LOG_COMPILED_OUT_()
#define log_success(...) ASI_LOG_COMPILED_OUT_()
#endif

#if RCLC_LOG_MIN_SEVERITY <= RCLC_LOG_MIN_SEVERITY_WARN
#define log_warn(...) ::common::logger::emit_(RCLC_LOG_SEVERITY_WARN, __VA_ARGS__)
#else
#define log_warn(...) ASI_LOG_COMPILED_OUT_()
#endif

#if RCLC_LOG_MIN_SEVERITY <= RCLC_LOG_MIN_SEVERITY_ERROR
#define log_error(...) ::common::logger::emit_(RCLC_LOG_SEVERITY_ERROR, __VA_ARGS__)
#else
#define log_error(...) ASI_LOG_COMPILED_OUT_()
#endif

// --- Per-cycle profiling instrumentation ------------------------------------
// Compiled out entirely unless the floor admits DEBUG: the default INFO build
// takes no timestamps and evaluates none of the log arguments, so the
// instrumentation adds zero latency/jitter to the control cycle it measures.
// Uses a monotonic clock (steady_clock) so an SNTP step cannot produce negative
// or garbled deltas. PROFILE_MS returns milliseconds as a double.
#if RCLC_LOG_MIN_SEVERITY <= RCLC_LOG_MIN_SEVERITY_DEBUG
#define PROFILE_POINT(name) const auto name = std::chrono::steady_clock::now()
#define PROFILE_MS(from, to) \
    (std::chrono::duration<double, std::milli>((to) - (from)).count())
#else
#define PROFILE_POINT(name) ((void)0)
#define PROFILE_MS(from, to) 0.0
#endif
#define PROFILE_LOG(...) log_debug(__VA_ARGS__)

#endif  // COMMON__LOGGER_LOGGER_HPP_
