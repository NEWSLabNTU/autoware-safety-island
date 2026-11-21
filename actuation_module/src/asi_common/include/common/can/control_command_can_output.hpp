#ifndef COMMON__CAN__CONTROL_COMMAND_CAN_OUTPUT_HPP_
#define COMMON__CAN__CONTROL_COMMAND_CAN_OUTPUT_HPP_

#include <cstddef>
#include <cstdint>
#include <pthread.h>

#include "autoware/autoware_msgs/messages.hpp"
#include "common/can/can_platform.hpp"
#include "common/can/control_command_encoder.hpp"
#include "common/can/control_command_output_mode.hpp"
#include "common/logger/logger.hpp"

namespace common::can
{

class ControlCommandCanOutput
{
public:
  ControlCommandCanOutput() = default;
  ControlCommandCanOutput(const ControlCommandCanOutput &) = delete;
  ControlCommandCanOutput & operator=(const ControlCommandCanOutput &) = delete;

  /// Open the CAN device: the image's (`device` nullptr) or the named one.
  /// `want_fd` sends the one-frame CAN-FD command instead of the classic
  /// three-frame batch; it is the application's choice, not the image's.
  bool init(const bool want_fd = false, const char * device = nullptr)
  {
    LockGuard lock(mutex_);
    fd_active_ = false;
    initialized_ = platform::can_init(want_fd, device);
    if (initialized_) {
      fd_active_ = platform::can_fd_active();
    }
    return initialized_;
  }

  bool initialized() const
  {
    LockGuard lock(mutex_);
    return initialized_;
  }

  bool send(const ControlMsg & msg, const ControlCommandOutputMode mode)
  {
    LockGuard lock(mutex_);

    if (!output_mode_uses_can(mode)) {
      return true;
    }

    if (!initialized_) {
      common::logger::log_error("CAN output is not initialized");
      return false;
    }

    if (fd_active_) {
      const auto encoded = encode_control_command_fd(msg, mode, sequence_);
      if (!encoded.ok) {
        common::logger::log_error("CAN-FD control command encoding failed: %s", encoded.error);
        return false;
      }

      if (encoded.count != 0U && !platform::can_send_fd(encoded.frame)) {
        common::logger::log_error("CAN-FD control command send failed");
        return false;
      }

      ++sequence_;
      return true;
    }

    const auto encoded = encode_control_command(msg, mode, sequence_);
    if (!encoded.ok) {
      common::logger::log_error("CAN control command encoding failed: %s", encoded.error);
      return false;
    }

    if (!platform::can_send_batch(encoded.frames.data(), encoded.count)) {
      common::logger::log_error("CAN control command batch send failed");
      return false;
    }

    ++sequence_;
    return true;
  }

private:
  class LockGuard
  {
  public:
    explicit LockGuard(pthread_mutex_t & mutex)
    : mutex_(mutex)
    {
      pthread_mutex_lock(&mutex_);
    }

    ~LockGuard()
    {
      pthread_mutex_unlock(&mutex_);
    }

    LockGuard(const LockGuard &) = delete;
    LockGuard & operator=(const LockGuard &) = delete;

  private:
    pthread_mutex_t & mutex_;
  };

  mutable pthread_mutex_t mutex_ = PTHREAD_MUTEX_INITIALIZER;
  bool initialized_{false};
  bool fd_active_{false};
  uint16_t sequence_{0U};
};

}  // namespace common::can

#endif  // COMMON__CAN__CONTROL_COMMAND_CAN_OUTPUT_HPP_
