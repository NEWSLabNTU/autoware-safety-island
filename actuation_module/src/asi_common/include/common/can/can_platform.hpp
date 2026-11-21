// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0

#ifndef COMMON__CAN__CAN_PLATFORM_HPP_
#define COMMON__CAN__CAN_PLATFORM_HPP_

// The CAN output's driver: a thin wrapper over nano-ros's platform CAN frame
// driver (<nros/platform_can.h>, RFC-0132). The board picks the backend
// (Zephyr's CAN API, SocketCAN on a Linux-process board, a board package's
// driver, the census mock) and the image names the device: devicetree on
// Zephyr (the `nros,can` chosen, else `zephyr,canbus`), `[image.<id>.can]
// device` in system.toml on a host board. The island keeps the frame ids,
// the payload layout and the classic/FD choice (want_fd).
//
// CONFIG_CONTROL_CMD_CAN_OUTPUT says whether the image builds the CAN output
// at all. On Zephyr it is Kconfig: an image with neither CONFIG_CAN nor the
// UDP tunnel has no backend, and without the symbol nothing here references
// the driver, so it still links and can_init() fails. On every other board
// asi_common defines it: each links a backend (SocketCAN, nano-ros's
// fail-loud defaults whose open returns ENOTSUP, or the census mock).

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "common/can/can_fd_frame.hpp"
#include "common/can/can_frame.hpp"
#include "common/logger/logger.hpp"

#if defined(CONFIG_CONTROL_CMD_CAN_OUTPUT) && CONFIG_CONTROL_CMD_CAN_OUTPUT
  #include <nros/platform_can.h>
  #define ASI_CAN_OUTPUT_BUILT 1
#else
  #define ASI_CAN_OUTPUT_BUILT 0
#endif

namespace common::can::platform
{

// How long a send waits for the controller to take a frame.
constexpr uint32_t kCanSendTimeoutUs = 10000U;

#if ASI_CAN_OUTPUT_BUILT

inline nros_platform_can_t & can_handle()
{
  static nros_platform_can_t handle{};
  return handle;
}

inline const char * can_error_name(const int8_t rc)
{
  switch (rc) {
    case NROS_PLATFORM_CAN_OK:
      return "ok";
    case NROS_PLATFORM_CAN_EINVAL:
      return "invalid frame";
    case NROS_PLATFORM_CAN_ENOTOPEN:
      return "not open";
    case NROS_PLATFORM_CAN_ENOFD:
      return "CAN-FD not active";
    case NROS_PLATFORM_CAN_EAGAIN:
      return "queue full";
    case NROS_PLATFORM_CAN_EBUSOFF:
      return "bus-off";
    case NROS_PLATFORM_CAN_ENOTSUP:
      return "not supported";
    case NROS_PLATFORM_CAN_ENODEV:
      return "no such device";
    default:
      return "I/O error";
  }
}

/// Open the image's CAN device (`device` nullptr), or the named one. With
/// `want_fd` the device must carry CAN-FD; a backend that can tell at open
/// that it does not (SocketCAN reads the MTU) fails here.
inline bool can_init(const bool want_fd = false, const char * device = nullptr)
{
  nros_platform_can_t & handle = can_handle();
  nros_platform_can_close(&handle);
  handle = nros_platform_can_t{};
  const int8_t rc = nros_platform_can_open(&handle, device, want_fd ? 1U : 0U);
  const char * name = device != nullptr ? device : "the image's CAN device";
  if (rc != NROS_PLATFORM_CAN_OK) {
    common::logger::log_error(
      "CAN open failed for %s (format=%s): %s (%d)",
      name, want_fd ? "fd" : "classic", can_error_name(rc), static_cast<int>(rc));
    return false;
  }
  common::logger::log_info(
    "CAN opened %s (format=%s, fd_active=%d)",
    name, want_fd ? "fd" : "classic", static_cast<int>(nros_platform_can_fd_active(&handle)));
  return true;
}

inline bool can_fd_active()
{
  return nros_platform_can_fd_active(&can_handle()) != 0U;
}

inline bool can_send(const CanFrame & frame)
{
  if (frame.dlc > kCanMaxDataLength) {
    common::logger::log_error("CAN frame id=0x%03x has dlc=%u", static_cast<unsigned int>(frame.id),
      static_cast<unsigned int>(frame.dlc));
    return false;
  }
  nros_platform_can_frame_t wire{};
  wire.id = frame.id;
  wire.flags = frame.extended ? NROS_PLATFORM_CAN_FLAG_EXT : 0U;
  wire.len = frame.dlc;
  std::memcpy(wire.data, frame.data.data(), frame.dlc);
  const int8_t rc = nros_platform_can_send(&can_handle(), &wire, kCanSendTimeoutUs);
  if (rc != NROS_PLATFORM_CAN_OK) {
    common::logger::log_error(
      "CAN send failed for id=0x%03x: %s (%d)",
      static_cast<unsigned int>(frame.id), can_error_name(rc), static_cast<int>(rc));
    return false;
  }
  return true;
}

inline bool can_send_fd(const CanFdFrame & frame)
{
  if (frame.length > kCanFdMaxDataLength) {
    common::logger::log_error(
      "CAN-FD frame id=0x%03x has length=%u", static_cast<unsigned int>(frame.id),
      static_cast<unsigned int>(frame.length));
    return false;
  }
  nros_platform_can_frame_t wire{};
  wire.id = frame.id;
  wire.flags = static_cast<uint8_t>(
    NROS_PLATFORM_CAN_FLAG_FD | (frame.brs ? NROS_PLATFORM_CAN_FLAG_BRS : 0U));
  wire.len = frame.length;
  std::memcpy(wire.data, frame.data.data(), frame.length);
  const int8_t rc = nros_platform_can_send(&can_handle(), &wire, kCanSendTimeoutUs);
  if (rc != NROS_PLATFORM_CAN_OK) {
    common::logger::log_error(
      "CAN-FD send failed for id=0x%03x: %s (%d)",
      static_cast<unsigned int>(frame.id), can_error_name(rc), static_cast<int>(rc));
    return false;
  }
  return true;
}

#else  // !ASI_CAN_OUTPUT_BUILT

inline bool can_init(const bool = false, const char * = nullptr)
{
  common::logger::log_error("CAN output is not built into this image");
  return false;
}

inline bool can_fd_active()
{
  return false;
}

inline bool can_send(const CanFrame &)
{
  return false;
}

inline bool can_send_fd(const CanFdFrame &)
{
  return false;
}

#endif  // ASI_CAN_OUTPUT_BUILT

/// The classic three-frame command, frame by frame; stops at the first
/// failure.
inline bool can_send_batch(const CanFrame * frames, const std::size_t count)
{
  for (std::size_t index = 0U; index < count; ++index) {
    if (!can_send(frames[index])) {
      return false;
    }
  }
  return true;
}

}  // namespace common::can::platform

#endif  // COMMON__CAN__CAN_PLATFORM_HPP_
