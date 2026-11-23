#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Runs inside the network namespace scripts/run-in-netns.sh gives a test (a
# container, or a CI job container started with the same capabilities). As
# root it creates the devices the test asks for, then runs the test, as the
# calling user unless --root. Nothing here touches the host's interfaces:
# this namespace has none of them.
#
#   entry.sh [--vcan] [--tap] [--root] -- <cmd> [args...]
#
#   --vcan  vcan0, MTU 72 (CAN-FD), up
#   --tap   tap0 owned by NETNS_UID, 192.168.10.1/24, up (the FVP tap
#           network's host side, net-fvp-tap.toml)
#   --root  run <cmd> as root (a test that changes a link, e.g. vcan0's MTU)

set -euo pipefail

want_vcan=0
want_tap=0
as_root=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vcan) want_vcan=1 ;;
    --tap) want_tap=1 ;;
    --root) as_root=1 ;;
    --) shift; break ;;
    *) echo "netns entry: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ $# -gt 0 ] || { echo "netns entry: no command" >&2; exit 2; }

uid="${NETNS_UID:-0}"
gid="${NETNS_GID:-0}"
VCAN="${VCAN_IFACE:-vcan0}"
TAP="${FVP_TAP_INTERFACE:-tap0}"
TAP_CIDR="${NETNS_TAP_CIDR:-192.168.10.1/24}"

ip link set lo up

if [ "${want_vcan}" = "1" ]; then
  # The vcan module is the host kernel's; creating the link asks the kernel
  # to load it when it is not loaded yet.
  if ! ip link show "${VCAN}" >/dev/null 2>&1; then
    ip link add "${VCAN}" type vcan
  fi
  ip link set dev "${VCAN}" down
  ip link set dev "${VCAN}" mtu 72
  ip link set dev "${VCAN}" up
  echo "netns: ${VCAN} up (mtu 72)"
fi

if [ "${want_tap}" = "1" ]; then
  [ -c /dev/net/tun ] || { echo "netns: /dev/net/tun is missing" >&2; exit 1; }
  if ! ip link show "${TAP}" >/dev/null 2>&1; then
    # Owned by the test's user, so the model opens it without CAP_NET_ADMIN.
    ip tuntap add dev "${TAP}" mode tap user "${uid}"
  fi
  ip addr replace "${TAP_CIDR}" dev "${TAP}"
  ip link set dev "${TAP}" up
  echo "netns: ${TAP} up (${TAP_CIDR}, owner ${uid})"
fi

if [ "${as_root}" = "1" ] || [ "${uid}" = "0" ]; then
  exec "$@"
fi
# HOME may not exist in the container; the model and python want a writable one.
export HOME="${NETNS_HOME:-/tmp/netns-home}"
mkdir -p "${HOME}"
chown "${uid}:${gid}" "${HOME}"
exec setpriv --reuid="${uid}" --regid="${gid}" --clear-groups "$@"
