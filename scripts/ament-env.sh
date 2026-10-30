#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Resolve AMENT_PREFIX_PATH to something that can feed the message codegen.
#
# Sourced by build.sh, and by the FVP CI script before it starts a model with
# `west build --target run`. That command RE-ENTERS cmake, and a reconfigure
# without this resolution dies on the first .msg it looks for:
#
#   nros_generate_interfaces(): cannot find 'msg/Odometry.msg' for package
#   'nav_msgs'.  Hint: source your ROS 2 setup.bash or set AMENT_PREFIX_PATH.
#
# The build that produced the ELF had the environment; the reconfigure that ran
# the ELF did not. Same shape as the nano-ros knobs (scripts/zephyr-nros-knobs.sh)
# and the loader paths (add_ros_lib_paths in .github/scripts/ci-helpers.sh):
# whatever build.sh resolves, the run has to resolve identically.

# Colours when sourced outside build.sh, which defines its own.
GREEN="${GREEN:-}"
RED="${RED:-}"
YELLOW="${YELLOW:-}"
NC="${NC:-}"

# The message packages the vendored codegen reads (autoware_msgs/CMakeLists.txt).
# They do NOT all live in one prefix: an Autoware install carries
# autoware_adapi_v1_msgs and tier4_debug_msgs that the ROS base does not, so a
# resolver that stops at the first prefix answering for autoware_planning_msgs
# selects a path the build then dies on.
ASI_MSG_PKGS=(
  autoware_adapi_v1_msgs autoware_control_msgs autoware_perception_msgs
  autoware_planning_msgs autoware_vehicle_msgs tier4_debug_msgs
  std_msgs geometry_msgs nav_msgs builtin_interfaces
)

# Echoes the required packages that no prefix on AMENT_PREFIX_PATH provides.
# Empty output means the environment can feed the codegen.
function ament_missing_msg_pkgs() {
  local pkg prefix found
  for pkg in "${ASI_MSG_PKGS[@]}"; do
    found=""
    local IFS=:
    for prefix in ${AMENT_PREFIX_PATH:-}; do
      if [ -d "${prefix}/share/${pkg}/msg" ]; then found=1; break; fi
    done
    [ -n "${found}" ] || printf '%s ' "${pkg}"
  done
}

function resolve_ament_env() {
  local tried=()
  # UNION, not first match. Every source below contributes prefixes and the
  # probe runs at the end, because the packages are genuinely spread across
  # installs.
  if [ -z "${AMENT_PREFIX_PATH:-}" ]; then
    # An image can ship Autoware merged (/opt/autoware/share/<pkg>), isolated
    # (/opt/autoware/<version>/share/<pkg>), or as the ROS base alone. Sourcing
    # the environment's own setup.bash settles the layout without this script
    # having to know it -- which is what CI needed: there the directory probes
    # found only /opt/ros/humble and the build died on the packages it lacks.
    local setup
    for setup in /opt/autoware/setup.bash "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" \
                 /opt/ros/humble/setup.bash; do
      [ -f "${setup}" ] || continue
      tried+=("${setup}")
      set +u
      # shellcheck disable=SC1090
      . "${setup}" >/dev/null 2>&1 || true
      set -u
      [ -z "$(ament_missing_msg_pkgs)" ] && break
    done
  fi
  if [ -n "$(ament_missing_msg_pkgs)" ]; then
    local rungs=() d
    [ -d /opt/ros/humble/share ] && rungs+=(/opt/ros/humble)
    [ -d /opt/autoware/share ] && rungs+=(/opt/autoware)
    for d in $(ls -d /opt/autoware/*/share 2>/dev/null | sort -Vr); do
      rungs+=("$(dirname "${d}")")
    done
    if [ ${#rungs[@]} -gt 0 ]; then
      tried+=("${rungs[@]}")
      AMENT_PREFIX_PATH="${AMENT_PREFIX_PATH:+${AMENT_PREFIX_PATH}:}$(IFS=:; echo "${rungs[*]}")"
      export AMENT_PREFIX_PATH
      echo -e "${GREEN}AMENT_PREFIX_PATH extended with: ${rungs[*]}${NC}"
    fi
  fi
  local missing
  missing="$(ament_missing_msg_pkgs)"
  if [ -n "${missing}" ]; then
    # Last resort: FIND the installs rather than predict them. Autoware images
    # have placed them under /opt/autoware, /autoware/install and ~/autoware
    # over time, merged or isolated, and a build that dies guessing is worse
    # than one bounded search.
    local pkg hit root
    for pkg in ${missing}; do
      for root in /opt /autoware "${HOME}/autoware"; do
        [ -d "${root}" ] || continue
        tried+=("find ${root} for ${pkg}")
        hit="$(find "${root}" -maxdepth 6 -type d -path "*/share/${pkg}/msg" \
               -print -quit 2>/dev/null)"
        if [ -n "${hit}" ]; then
          hit="${hit%/share/${pkg}/msg}"
          AMENT_PREFIX_PATH="${AMENT_PREFIX_PATH:+${AMENT_PREFIX_PATH}:}${hit}"
          export AMENT_PREFIX_PATH
          echo -e "${GREEN}found ${pkg} by search in ${hit}${NC}"
          break
        fi
      done
    done
    missing="$(ament_missing_msg_pkgs)"
  fi
  if [ -n "${missing}" ]; then
    echo -e "${RED}message packages not found in AMENT_PREFIX_PATH: ${missing}${NC}" 1>&2
    echo -e "${YELLOW}Source a ROS 2 Humble + Autoware environment (or set AMENT_PREFIX_PATH)"\
" -- message .msg sources resolve from it since phase-5 W1.${NC}" 1>&2
    # Name what was searched AND what is missing. The old message reported only
    # autoware_planning_msgs, which is indistinguishable from looking in the
    # wrong place -- and was misleading twice over, since that package was
    # present and a different one was not.
    echo -e "${YELLOW}searched: ${tried[*]:-(nothing -- no setup.bash and no /opt prefixes)}${NC}" 1>&2
    echo -e "${YELLOW}AMENT_PREFIX_PATH=${AMENT_PREFIX_PATH:-unset}${NC}" 1>&2
    exit 1
  fi
}
