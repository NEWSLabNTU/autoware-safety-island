// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// The FVP's CAN frame driver: nano-ros's <nros/platform_can.h> calls over the
// island's UDP tunnel (CONFIG_CONTROL_CMD_CAN_TRANSPORT_UDP_TUNNEL). The FVP
// models no CAN controller, so the three-frame control command (0x100, 0x101,
// 0x102) travels as one 48-byte datagram (common/can/can_udp_tunnel.hpp) to a
// host gateway (demo/can_tunnel_bridge), which puts the frames on a vcan.
//
// These are the strong nros_platform_can_* symbols of the image (RFC-0132 D3,
// the `board` hook): compiled into `app`, an object of the image, never an
// archive member. CONFIG_CAN is off on a tunnel image, so nano-ros's Zephyr
// backend is not linked beside them.
//
// The datagram carries a whole command, so send() queues 0x100 and 0x101 and
// sends the datagram on 0x102, with the sequence the status frame carries.
// A frame out of that order, or any other frame, is refused and drops the
// partial command. The bytes are unchanged from the tunnel's earlier
// can_send_batch(): the same pack_can_udp_tunnel() over the same frames.

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <nros/platform_can.h>

#include "common/can/can_frame.hpp"
#include "common/can/can_udp_tunnel.hpp"
#include "common/can/control_command_encoder.hpp"
#include "common/logger/logger.hpp"

namespace
{

// "ASUT": an open tunnel handle. A zeroed handle is closed.
constexpr uint32_t kTunnelOpenMagic = 0x41535554U;

struct TunnelCan
{
  uint32_t magic;
  int32_t socket_fd;
  uint8_t pending;  // frames of the current command queued (0..2)
};

NROS_PLATFORM_CAN_STORAGE_FITS(TunnelCan);

// The partial command; one tunnel per image, as one CAN device.
common::can::CanFrame g_frames[common::can::kControlCommandCanFrameCount];
sockaddr_in g_peer{};

TunnelCan * tunnel_state(const nros_platform_can_t * can)
{
  if (can == nullptr) {
    return nullptr;
  }
  auto * state = reinterpret_cast<TunnelCan *>(const_cast<nros_platform_can_t *>(can));
  return state->magic == kTunnelOpenMagic ? state : nullptr;
}

constexpr uint32_t kCommandIds[common::can::kControlCommandCanFrameCount] = {
  common::can::kLateralCommandCanId,
  common::can::kLongitudinalCommandCanId,
  common::can::kCommandStatusCanId,
};

}  // namespace

extern "C" int8_t nros_platform_can_open(
  nros_platform_can_t * can, const char * device, uint8_t want_fd)
{
  (void)want_fd;  // classic frames only: fd_active stays 0
  if (can == nullptr) {
    return NROS_PLATFORM_CAN_EINVAL;
  }
  if (device != nullptr) {
    common::logger::log_error("CAN UDP tunnel: no device named %s (the tunnel is the image's only one)",
      device);
    return NROS_PLATFORM_CAN_ENODEV;
  }

  sockaddr_in peer{};
  peer.sin_family = AF_INET;
  peer.sin_port = htons(static_cast<uint16_t>(CONFIG_CONTROL_CMD_CAN_TUNNEL_PORT));
  if (inet_pton(AF_INET, CONFIG_CONTROL_CMD_CAN_TUNNEL_PEER, &peer.sin_addr) != 1) {
    common::logger::log_error(
      "CAN UDP tunnel peer is invalid: %s", CONFIG_CONTROL_CMD_CAN_TUNNEL_PEER);
    return NROS_PLATFORM_CAN_EINVAL;
  }

  const int socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (socket_fd < 0) {
    common::logger::log_error("CAN UDP socket failed: %s", std::strerror(errno));
    return NROS_PLATFORM_CAN_EIO;
  }
  const int flags = fcntl(socket_fd, F_GETFL, 0);
  if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    common::logger::log_error("CAN UDP O_NONBLOCK failed: %s", std::strerror(errno));
    close(socket_fd);
    return NROS_PLATFORM_CAN_EIO;
  }

  auto * state = reinterpret_cast<TunnelCan *>(can);
  state->magic = kTunnelOpenMagic;
  state->socket_fd = socket_fd;
  state->pending = 0U;
  g_peer = peer;
  common::logger::log_info(
    "CAN UDP tunnel initialized to %s:%d",
    CONFIG_CONTROL_CMD_CAN_TUNNEL_PEER,
    CONFIG_CONTROL_CMD_CAN_TUNNEL_PORT);
  return NROS_PLATFORM_CAN_OK;
}

extern "C" int8_t nros_platform_can_send(
  nros_platform_can_t * can, const nros_platform_can_frame_t * frame, uint32_t timeout_us)
{
  (void)timeout_us;  // a non-blocking datagram socket
  TunnelCan * state = tunnel_state(can);
  if (state == nullptr) {
    return NROS_PLATFORM_CAN_ENOTOPEN;
  }
  const int8_t rc = nros_platform_can_frame_check(frame, 0U);
  if (rc != NROS_PLATFORM_CAN_OK) {
    state->pending = 0U;
    return rc;
  }
  if ((frame->flags & NROS_PLATFORM_CAN_SEND_WAIT_TX) != 0U) {
    return NROS_PLATFORM_CAN_ENOTSUP;
  }
  const uint8_t index = state->pending;
  if ((frame->flags & NROS_PLATFORM_CAN_FLAG_EXT) != 0U || frame->id != kCommandIds[index] ||
    frame->len != common::can::kCanMaxDataLength)
  {
    common::logger::log_error(
      "CAN UDP tunnel: frame id=0x%03x len=%u is not frame %u of a control command",
      static_cast<unsigned int>(frame->id), static_cast<unsigned int>(frame->len),
      static_cast<unsigned int>(index));
    state->pending = 0U;
    return NROS_PLATFORM_CAN_EINVAL;
  }

  common::can::CanFrame & queued = g_frames[index];
  queued = common::can::CanFrame{};
  queued.id = frame->id;
  queued.dlc = frame->len;
  std::memcpy(queued.data.data(), frame->data, frame->len);
  if (index + 1U < common::can::kControlCommandCanFrameCount) {
    state->pending = static_cast<uint8_t>(index + 1U);
    return NROS_PLATFORM_CAN_OK;
  }
  state->pending = 0U;

  const uint16_t sequence = static_cast<uint16_t>(
    static_cast<uint16_t>(g_frames[2].data[2]) |
    (static_cast<uint16_t>(g_frames[2].data[3]) << 8));
  const auto packed =
    common::can::pack_can_udp_tunnel(g_frames, common::can::kControlCommandCanFrameCount, sequence);
  if (!packed.ok) {
    common::logger::log_error("CAN UDP pack failed: %s", packed.error);
    return NROS_PLATFORM_CAN_EINVAL;
  }
  const ssize_t sent = sendto(
    state->socket_fd, packed.bytes.data(), packed.bytes.size(), 0,
    reinterpret_cast<const sockaddr *>(&g_peer), sizeof(g_peer));
  if (sent != static_cast<ssize_t>(packed.bytes.size())) {
    common::logger::log_error("CAN UDP send failed: %s", std::strerror(errno));
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? NROS_PLATFORM_CAN_EAGAIN
                                                     : NROS_PLATFORM_CAN_EIO;
  }
  return NROS_PLATFORM_CAN_OK;
}

extern "C" uint8_t nros_platform_can_fd_active(const nros_platform_can_t * can)
{
  (void)can;
  return 0U;
}

extern "C" int8_t nros_platform_can_recv(
  nros_platform_can_t * can, nros_platform_can_frame_t * frame, uint32_t timeout_us)
{
  (void)frame;
  (void)timeout_us;
  return tunnel_state(can) == nullptr ? NROS_PLATFORM_CAN_ENOTOPEN : NROS_PLATFORM_CAN_ENOTSUP;
}

extern "C" void nros_platform_can_close(nros_platform_can_t * can)
{
  TunnelCan * state = tunnel_state(can);
  if (state == nullptr) {
    return;
  }
  close(state->socket_fd);
  std::memset(can, 0, sizeof(*can));
}
