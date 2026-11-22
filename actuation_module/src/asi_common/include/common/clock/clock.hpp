#ifndef COMMON__CLOCK_HPP_
#define COMMON__CLOCK_HPP_

#include <chrono>
#include <cstdio>
#include <cstdint>
#include <ctime>

#include "common/logger/logger.hpp"

// nano-ros's clocks. The steady one is the port's monotonic clock on every
// target. The wall clock is nano-ros's too (phase-15 P5):
//   - Zephyr: the image states its source in [knobs.clock]
//     (controller_bringup/system.toml), and nano-ros resolves it once at boot,
//     after every component has registered and before anything spins
//     (nano-ros phase-582, RFC-0141). Its reading is an offset from the
//     monotonic clock kept by nano-ros; Zephyr's CLOCK_REALTIME is never set
//     on these images.
//   - bare-metal FreeRTOS (mps3-an536, S32Z270): newlib's gettimeofday and
//     libstdc++'s system_clock are nano-ros's shims over
//     nros_platform_time_now_ns (phase-582 W2), which reads 0 while no source
//     is synced. FreeRTOS has no source to resolve yet (`platform` is "none"
//     there; a board clock waits on phase-582 W1d), so these images stamp
//     boot-relative.
//   - the FreeRTOS POSIX simulator: glibc's clock, the host's.
#include <rclcpp/clock.hpp>
using namespace common::logger;

// nros-cpp generated builtin_interfaces (asi_common's package.xml <depend>).
#include <builtin_interfaces/msg/duration.hpp>
#include <builtin_interfaces/msg/time.hpp>
using TimeMsg = builtin_interfaces::msg::Time;
using DurationMsg = builtin_interfaces::msg::Duration;

class Clock {
public:

    /**
     * @brief The stamp clock: wall-clock time in seconds.
     *
     * What every outgoing stamp carries, and what the vendored follower's
     * own stamp arithmetic reads. On Zephyr it is nano-ros's wall clock
     * (`rclcpp::Clock(RCL_SYSTEM_TIME)`); elsewhere it is the C library's
     * (`std::chrono::system_clock`), the host's on the POSIX simulator and
     * nano-ros's shim over the same wall-clock symbol on bare-metal FreeRTOS.
     * Before that clock is synced (before boot resolution, or for the whole
     * run when no source answered) nano-ros reads 0, and this answers the
     * time since boot instead, so the follower's intervals keep advancing and
     * the stamps are boot-relative, as they were on every image without SNTP.
     *
     * The platform test stays while the FreeRTOS POSIX simulator's nano-ros
     * wall clock reads 0 (its port has no source, while glibc has the host's
     * clock); once it answers, every target can read RCL_SYSTEM_TIME.
     *
     * Not for ages and timeouts: a source that answers later may step it.
     * Use steady_now() for those.
     *
     * @return current wall-clock time in seconds
     */
    static double now() {
#if defined(PLATFORM_ZEPHYR)
        if (rclcpp::Clock::wall_clock_state().synced) {
            const int64_t ns = rclcpp::Clock(RCL_SYSTEM_TIME).now().nanoseconds();
            if (ns > 0) {
                return static_cast<double>(ns) * 1e-9;
            }
        }
        return steady_now();
#else
        const int64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        if (ns > 0) {
            return static_cast<double>(ns) * 1e-9;
        }
        return steady_now();
#endif
    }

    /**
     * @brief The age clock: monotonic time since boot, in seconds.
     *
     * For input ages, timeouts and re-enable windows. Never stepped, so a
     * wall-clock source that answers late (or steps) can neither fire nor
     * mask the staleness gate. Never subtract a stamp from it.
     *
     * @return monotonic time in seconds
     */
    static double steady_now() {
        // nano-ros's monotonic clock, read through rclcpp so that no
        // target's libstdc++ steady_clock is relied on (the bare-metal
        // newlib one is gettimeofday unless nano-ros's board defines it).
        const int64_t ns = rclcpp::Clock(RCL_STEADY_TIME).now().nanoseconds();
        return static_cast<double>(ns) * 1e-9;
    }

    /**
     * @brief Convert time in seconds to ROS2 time
     * @param time: time in seconds
     * @return ROS2 Time Message
     */
    static TimeMsg toRosTime(const double time) {
        const auto nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::duration<double>(time));
        constexpr int64_t nano_per_sec = 1'000'000'000;

        TimeMsg ros_time;
        const auto count = nanoseconds.count();
        ros_time.sec = static_cast<int32_t>(count / nano_per_sec);
        ros_time.nanosec = static_cast<uint32_t>(count % nano_per_sec);

        return ros_time;
    }

    /**
     * @brief Convert time in seconds to ROS2 duration
     * @param time: time in seconds
     * @return ROS2 Duration Message
     */
    static DurationMsg toRosDuration(const double time) {
        const auto nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::duration<double>(time));
        constexpr int64_t nano_per_sec = 1'000'000'000;

        DurationMsg ros_duration;
        const auto count = nanoseconds.count();
        ros_duration.sec = static_cast<int32_t>(count / nano_per_sec);
        ros_duration.nanosec = static_cast<uint32_t>(count % nano_per_sec);

        return ros_duration;
    }

    /**
     * @brief Convert ROS2 time to time in seconds
     * @param ros_time: ROS2 Time Message
     * @return time in seconds
     */
    static double toDouble(const TimeMsg& ros_time) {
        const int64_t total_ns = static_cast<int64_t>(ros_time.sec) * 1'000'000'000LL
                                + ros_time.nanosec;
        return std::chrono::duration_cast<std::chrono::duration<double>>(
            std::chrono::nanoseconds(total_ns)
        ).count();
    }
private:
    Clock() = default;
    ~Clock() = default;
};

#endif  // COMMON__CLOCK_HPP_
