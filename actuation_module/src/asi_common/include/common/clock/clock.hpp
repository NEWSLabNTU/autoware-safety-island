#ifndef COMMON__CLOCK_HPP_
#define COMMON__CLOCK_HPP_

#include <chrono>
#include <cstdio>
#include <cstdint>
#include <ctime>

#include "common/logger/logger.hpp"

// nano-ros's clocks. The steady one is the port's monotonic clock on every
// target. The Zephyr images also take their wall clock from it: the image
// states its source in [knobs.clock] (controller_bringup/system.toml), and
// nano-ros resolves it once at boot, after every component has registered and
// before anything spins (nano-ros phase-582, RFC-0141). Its reading is an
// offset from the monotonic clock kept by nano-ros; Zephyr's CLOCK_REALTIME
// is never set on these images.
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
     * (`rclcpp::Clock(RCL_SYSTEM_TIME)`); before that clock is synced (before
     * boot resolution, or for the whole run when no source answered and the
     * image's clock.epoch_failure is `unstamped`) nano-ros reads 0, and this
     * answers the time since boot instead, so the follower's intervals keep
     * advancing and the stamps are boot-relative, as they were on every
     * image without SNTP. On FreeRTOS it is the C library's wall clock: the
     * host's on the POSIX simulator, the island's SNTP epoch
     * (src/platform/freertos/wall_clock.cpp) on bare metal.
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
        auto time_point = std::chrono::system_clock::now();
        return std::chrono::duration<double>(time_point.time_since_epoch()).count();
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
        // nano-ros's monotonic clock, not std::chrono::steady_clock: on the
        // bare-metal FreeRTOS lanes newlib's libstdc++ may answer
        // steady_clock from gettimeofday, which there is the island's SNTP
        // wall clock (src/platform/freertos/wall_clock.cpp).
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
