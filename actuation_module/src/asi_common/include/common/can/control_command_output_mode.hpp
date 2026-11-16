#ifndef COMMON__CAN__CONTROL_COMMAND_OUTPUT_MODE_HPP_
#define COMMON__CAN__CONTROL_COMMAND_OUTPUT_MODE_HPP_

#include <cstdint>

namespace common::can
{

enum class ControlCommandOutputMode : uint8_t
{
  DDS_ONLY = 0U,
  CAN_ONLY = 1U,
  DDS_AND_CAN = 2U,
};

constexpr bool output_mode_uses_dds(const ControlCommandOutputMode mode)
{
  return mode == ControlCommandOutputMode::DDS_ONLY || mode == ControlCommandOutputMode::DDS_AND_CAN;
}

constexpr bool output_mode_uses_can(const ControlCommandOutputMode mode)
{
  return mode == ControlCommandOutputMode::CAN_ONLY || mode == ControlCommandOutputMode::DDS_AND_CAN;
}

constexpr const char * output_mode_name(const ControlCommandOutputMode mode)
{
  switch (mode) {
    case ControlCommandOutputMode::DDS_ONLY:
      return "DDS_ONLY";
    case ControlCommandOutputMode::CAN_ONLY:
      return "CAN_ONLY";
    case ControlCommandOutputMode::DDS_AND_CAN:
      return "DDS_AND_CAN";
  }
  return "DDS_ONLY";
}

/// Phase 4 (0745 follow-up) — parse a launch-seeded `control_output` string.
/// Unknown/empty falls back to `fallback`.
inline ControlCommandOutputMode output_mode_from_name(
  const char * name, const ControlCommandOutputMode fallback)
{
  if (name == nullptr) {
    return fallback;
  }
  const auto eq = [name](const char * s) {
    const char * a = name;
    const char * b = s;
    while (*a != '\0' && *a == *b) { ++a; ++b; }
    return *a == '\0' && *b == '\0';
  };
  if (eq("DDS_ONLY")) return ControlCommandOutputMode::DDS_ONLY;
  if (eq("CAN_ONLY")) return ControlCommandOutputMode::CAN_ONLY;
  if (eq("DDS_AND_CAN")) return ControlCommandOutputMode::DDS_AND_CAN;
  return fallback;
}

/// The mode when the `control_output` parameter is unset or unknown: the
/// launch arg's own default (system.launch.xml). The deployment owns the
/// mode; whether the image can send CAN at all is CONFIG_CONTROL_CMD_CAN_OUTPUT.
constexpr ControlCommandOutputMode default_control_command_output_mode()
{
  return ControlCommandOutputMode::DDS_ONLY;
}

}  // namespace common::can

#endif  // COMMON__CAN__CONTROL_COMMAND_OUTPUT_MODE_HPP_
