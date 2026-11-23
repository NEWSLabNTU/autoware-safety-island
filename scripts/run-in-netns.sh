#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# run-in-netns.sh -- run a network test in a network namespace of its own,
# with no sudo and no password.
#
# The CAN and tap tests need a vcan0 and a tap0 they can configure
# (CAP_NET_ADMIN over them). This script starts a throwaway container with
# exactly
#
#   docker run --rm --cap-add NET_ADMIN --device /dev/net/tun --network none
#
# (plus --cap-add SYS_NICE with --sys-nice), creates the devices inside it
# (scripts/netns/entry.sh) and runs the test there. The container's network
# namespace holds only lo and the test's devices: the host's interfaces,
# including a host vcan0, are neither seen nor touched. No --privileged, no
# host network. Docker must work without sudo (the user is in the docker
# group).
#
#   scripts/run-in-netns.sh [--vcan] [--tap] [--root] [--sys-nice]
#                           [--ro PATH]... [--env NAME]... -- <cmd> [args...]
#
#   --vcan       create vcan0 (MTU 72, up)
#   --tap        create tap0 (owned by the caller, 192.168.10.1/24, up)
#   --root       run <cmd> as root in the container (default: as the caller,
#                after the devices exist)
#   --sys-nice   add CAP_SYS_NICE (tests that set real-time priorities)
#   --ro PATH    bind-mount PATH read-only at the same path (repeatable)
#   --env NAME   pass the caller's NAME into the container (repeatable)
#
# The repository is bind-mounted read-write at its own path and is the
# working directory; ARMFVP_BIN_PATH's install is mounted read-only when set.
# Build outputs that live outside the repository need --ro.
#
# The image is scripts/netns/Dockerfile (Ubuntu 22.04 + iproute2, python3,
# can-utils), built on first use and tagged by the Dockerfile's hash.
#
# On a CI job container that already has NET_ADMIN and /dev/net/tun (the
# workflow's container options) there is no docker to call: set
# ASI_NETNS_DIRECT=1 and the devices are made in the job container's own
# namespace (it is not the runner's).
#
# Examples:
#   scripts/run-in-netns.sh --vcan --root -- \
#     actuation_module/test/run-vcan-roundtrip.sh build/freertos-posix-can/can_vcan_sender
#   scripts/run-in-netns.sh --vcan --tap -- \
#     actuation_module/test/run-fvp-tap-tunnel.sh build/zephyr-fvp-tap-can

set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
NETNS_DIR="${ROOT_DIR}/scripts/netns"

entry_args=()
sys_nice=0
ro_mounts=()
env_names=(ARMFVP_BIN_PATH ARMFVP_EXTRA_FLAGS FVP_TAP_INTERFACE
  FVP_TAP_TIMEOUT_SECONDS FVP_TAP_LOG_DIR VCAN_IFACE UDP_TUNNEL_BIND UDP_TUNNEL_PORT
  GITHUB_ACTIONS)
while [ $# -gt 0 ]; do
  case "$1" in
    --vcan|--tap|--root) entry_args+=("$1") ;;
    --sys-nice) sys_nice=1 ;;
    --ro) ro_mounts+=("$(realpath "$2")"); shift ;;
    --env) env_names+=("$2"); shift ;;
    --) shift; break ;;
    -h|--help) sed -n '5,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "run-in-netns: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ $# -gt 0 ] || { echo "run-in-netns: no command (see --help)" >&2; exit 2; }

if [ "${ASI_NETNS_DIRECT:-0}" = "1" ]; then
  cd "${ROOT_DIR}"
  export NETNS_UID="${NETNS_UID:-$(id -u)}" NETNS_GID="${NETNS_GID:-$(id -g)}"
  exec "${NETNS_DIR}/entry.sh" "${entry_args[@]}" -- "$@"
fi

command -v docker >/dev/null 2>&1 || {
  echo "run-in-netns: docker is not on PATH (or set ASI_NETNS_DIRECT=1 in a job container with NET_ADMIN)" >&2
  exit 1
}

tag="asi-netns-test:$(sha256sum "${NETNS_DIR}/Dockerfile" | cut -c1-12)"
if ! docker image inspect "${tag}" >/dev/null 2>&1; then
  echo "run-in-netns: building ${tag}"
  docker build -q -t "${tag}" -f "${NETNS_DIR}/Dockerfile" "${NETNS_DIR}" >/dev/null
fi

run=(docker run --rm --init
  --name "asi-netns-$$"
  --cap-add NET_ADMIN --device /dev/net/tun
  --network none
  -v "${ROOT_DIR}:${ROOT_DIR}" -w "${ROOT_DIR}"
  -e NETNS_UID="$(id -u)" -e NETNS_GID="$(id -g)"
  -e PYTHONDONTWRITEBYTECODE=1)
if [ "${sys_nice}" = "1" ]; then
  run+=(--cap-add SYS_NICE)
fi
if [ -n "${ARMFVP_BIN_PATH:-}" ]; then
  fvp_root="$(realpath "${ARMFVP_BIN_PATH}/..")"
  run+=(-v "${fvp_root}:${fvp_root}:ro")
fi
for m in "${ro_mounts[@]}"; do
  run+=(-v "${m}:${m}:ro")
done
for n in "${env_names[@]}"; do
  if [ -n "${!n+x}" ]; then
    run+=(-e "${n}=${!n}")
  fi
done

exec "${run[@]}" "${tag}" "${NETNS_DIR}/entry.sh" "${entry_args[@]}" -- "$@"
