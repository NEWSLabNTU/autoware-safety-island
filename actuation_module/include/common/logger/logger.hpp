#ifndef COMMON__LOGGER_LOGGER_HPP_
#define COMMON__LOGGER_LOGGER_HPP_

// Phase 5 W5 — one logging spine: the `log_*` API surface stays (20+
// vendored Autoware TUs call it), but the sink is nano-ros's `nros_log`
// dispatcher (`nros_log_emit_fmt` through the per-platform writer chain:
// POSIX stderr / Zephyr LOG / board fn-ptr on the FreeRTOS family). The
// old ASI-local implementation (colors, HH:MM:SS.mmm prefix, stderr) is
// gone — timestamps/format now come from the platform sink.
//
// Kept ASI-side (upstream has no equivalents yet):
//   * `log_*_throttle` — nros_log has no throttle macros (noted in
//     docs/roadmap/phase-5-legacy-cleanup.md W5).
//   * CONFIG_LOG_LEVEL compile-time gating — zero-cost below level; the
//     nros per-logger runtime threshold defaults to INFO and the C API
//     exposes no setter, so `log_debug`/PROFILE emit at INFO severity and
//     ASI's compile-time gate stays the debug on/off switch.

#include <chrono>
#include <map>
#include <cstdio>
#include <cstdarg>
#include <pthread.h>
#include "platform/platform_config.h"

#include <nros/log.h>

#define log_info_throttle(msg, ...) common::logger::log_info_throttle_(__FILE__, __LINE__, msg, ##__VA_ARGS__)
#define log_warn_throttle(msg, ...) common::logger::log_warn_throttle_(__FILE__, __LINE__, msg, ##__VA_ARGS__)

namespace common::logger {

// Lazy, idempotent sink bring-up. Hosted POSIX wires the dispatcher from
// .init_array; the no_std lanes (FreeRTOS/S32Z2) need the explicit
// `nros_log_init()` after the board's platform-log writer registers —
// calling it from a magic static covers both (idempotent upstream).
inline nros_logger_t default_logger_() {
    static const bool init_once = (nros_log_init(), true);
    (void)init_once;
    return nros_log_default_logger();
}

inline void vemit_(nros_log_severity_t severity, const char * format, va_list args) {
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    // Callers historically embed a trailing '\n'; the sink adds its own
    // line ending, so strip one trailing newline to avoid blank lines.
    size_t len = 0;
    while (buffer[len] != '\0') { ++len; }
    if (len > 0 && buffer[len - 1] == '\n') { buffer[len - 1] = '\0'; }
    nros_log_emit_fmt(default_logger_(), severity, "%s", buffer);
}

inline void log_success(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(NROS_LOG_SEVERITY_INFO, format, args);
    va_end(args);
    #endif
}

inline void log_info(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(NROS_LOG_SEVERITY_INFO, format, args);
    va_end(args);
    #endif
}

inline void log_warn(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(NROS_LOG_SEVERITY_WARN, format, args);
    va_end(args);
    #endif
}

inline void log_error(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 1
    va_list args;
    va_start(args, format);
    vemit_(NROS_LOG_SEVERITY_ERROR, format, args);
    va_end(args);
    #endif
}

inline void log_debug(const char * format, ...) {
    #if CONFIG_LOG_LEVEL >= 2
    va_list args;
    va_start(args, format);
    // INFO severity on purpose: the nros default threshold is INFO with no
    // C-side setter; ASI's compile-time gate is the debug switch.
    vemit_(NROS_LOG_SEVERITY_INFO, format, args);
    va_end(args);
    #endif
}

inline void log_info_throttle_(const char * file, int line, const char * format, ...)
{
    using clock = std::chrono::steady_clock;
    using time_point = clock::time_point;
    using duration = std::chrono::duration<double>;

    static pthread_mutex_t mutex_info = PTHREAD_MUTEX_INITIALIZER;
    static std::map<std::pair<const char*, int>, time_point> last_print_times;

    const double interval_seconds = CONFIG_LOG_THROTTLE_RATE;
    const auto location_key = std::make_pair(file, line);
    const auto now = clock::now();
    bool should_print = false;

    pthread_mutex_lock(&mutex_info);
    auto it = last_print_times.find(location_key);
    if (it == last_print_times.end()) {
        should_print = true;
        last_print_times.emplace(location_key, now);
    } else {
        const duration time_since_last_print = now - it->second;
        if (time_since_last_print.count() >= interval_seconds) {
            should_print = true;
            it->second = now;
        }
    }
    pthread_mutex_unlock(&mutex_info);

    if (should_print) {
        va_list args;
        va_start(args, format);
        vemit_(NROS_LOG_SEVERITY_INFO, format, args);
        va_end(args);
    }
}

inline void log_warn_throttle_(const char * file, int line, const char * format, ...)
{
    using clock = std::chrono::steady_clock;
    using time_point = clock::time_point;
    using duration = std::chrono::duration<double>;

    static std::map<std::pair<const char*, int>, time_point> last_print_times_warn;
    static pthread_mutex_t mutex_warn = PTHREAD_MUTEX_INITIALIZER;

    const double interval_seconds = CONFIG_LOG_THROTTLE_RATE;
    const auto location_key = std::make_pair(file, line);
    const auto now = clock::now();
    bool should_print = false;

    pthread_mutex_lock(&mutex_warn);
    auto it = last_print_times_warn.find(location_key);

    if (it == last_print_times_warn.end()) {
        should_print = true;
        last_print_times_warn.emplace(location_key, now);
    } else {
        const duration time_since_last_print = now - it->second;
        if (time_since_last_print.count() >= interval_seconds) {
            should_print = true;
            it->second = now;
        }
    }
    pthread_mutex_unlock(&mutex_warn);

    if (should_print) {
        va_list args;
        va_start(args, format);
        vemit_(NROS_LOG_SEVERITY_WARN, format, args);
        va_end(args);
    }
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
