#ifndef COMMON__CLOCK_HPP_
#define COMMON__CLOCK_HPP_

#include <chrono>
#include <cstdio>
#include <cstdint>
#include <ctime>

#include "common/logger/logger.hpp"

// nano-ros's clocks, on every target (phase-15 P5). The steady one is the
// port's monotonic clock. The wall clock is the source the image states in
// [knobs.clock] (controller_bringup/system.toml; nano-ros phase-582,
// RFC-0141), resolved once by nano-ros and kept as an offset from the
// monotonic clock:
//   - Zephyr: sntp (the tap and s32z images), or sntp then platform (the
//     user-mode FVP images), resolved at boot before anything spins.
//   - bare-metal FreeRTOS (mps3-an536, S32Z270): `board`, the island's SNTP
//     task behind nano-ros's board hook
//     (src/platform/freertos/board_wall_clock.cpp), resolved on the first
//     wall-clock read. newlib's gettimeofday and libstdc++'s system_clock are
//     nano-ros's shims over the same clock.
//   - the FreeRTOS POSIX simulator and the census's host images: `platform`,
//     the host's CLOCK_REALTIME.
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
     * own stamp arithmetic reads: nano-ros's wall clock
     * (`rclcpp::Clock(RCL_SYSTEM_TIME)`). Before it is synced (before
     * resolution, or for the whole run when no source answered and
     * clock.epoch_failure is `unstamped`) nano-ros reads 0, and this answers
     * the time since boot instead, so the follower's intervals keep advancing
     * and the stamps are boot-relative, as they were on every image without
     * a time source.
     *
     * Not for ages and timeouts: a source that answers later may step it.
     * Use steady_now() for those.
     *
     * @return current wall-clock time in seconds
     */
    static double now() {
        if (rclcpp::Clock::wall_clock_state().synced) {
            const int64_t ns = rclcpp::Clock(RCL_SYSTEM_TIME).now().nanoseconds();
            if (ns > 0) {
                return static_cast<double>(ns) * 1e-9;
            }
        }
        return steady_now();
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
