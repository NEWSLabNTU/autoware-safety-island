#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 3 W3 — configure the host TAP interface the zephyr-fvp `--network tap`
# profile expects (demo/README.md "Zephyr FVP Safety Island"): the FVP guest
# bridges its virtio NIC onto this device, and the demo compose stack's
# cyclonedds.xml pins DDS Domain 2 to it.
#
# Usage (as root):
#   sudo ./scripts/setup-tap.sh                 # create tap0, 192.168.10.1/24
#   sudo ./scripts/setup-tap.sh --user alice    # tap owner (default: SUDO_USER)
#   sudo ./scripts/setup-tap.sh --iface tap1 --cidr 192.168.20.1/24
#   sudo ./scripts/setup-tap.sh --delete        # tear the interface down
#
# Idempotent: re-running converges to the requested state. If you use a
# non-default --iface, export FVP_TAP_INTERFACE=<iface> before ./build.sh so
# the generated FVP runner command names the same device.

set -euo pipefail

say()  { echo -e "\033[0;32m[asi-tap]\033[0m $*"; }
warn() { echo -e "\033[0;33m[asi-tap]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[asi-tap]\033[0m $*" >&2; exit 1; }

IFACE="tap0"
CIDR="192.168.10.1/24"
TAP_USER="${SUDO_USER:-}"
DELETE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --iface)  IFACE="${2:?--iface needs a value}"; shift 2 ;;
    --cidr)   CIDR="${2:?--cidr needs a value}"; shift 2 ;;
    --user)   TAP_USER="${2:?--user needs a value}"; shift 2 ;;
    --delete) DELETE=1; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# ---- root check -------------------------------------------------------------
# TAP creation + addressing are CAP_NET_ADMIN operations; require root rather
# than half-failing partway through.
if [ "$(id -u)" -ne 0 ]; then
  die "must run as root — e.g.: sudo $0 $*"
fi

if [ "${DELETE}" = "1" ]; then
  if ip link show "${IFACE}" >/dev/null 2>&1; then
    ip link delete "${IFACE}"
    say "deleted ${IFACE}."
  else
    say "${IFACE} does not exist — nothing to delete."
  fi
  exit 0
fi

# The tap owner must be the (non-root) user who runs the FVP model, else the
# model cannot open the device. Under sudo that is SUDO_USER; require an
# explicit --user when invoked from a genuine root shell.
if [ -z "${TAP_USER}" ] || [ "${TAP_USER}" = "root" ]; then
  die "cannot determine the non-root tap owner — pass --user <name> (the user who runs FVP)."
fi
id -u "${TAP_USER}" >/dev/null 2>&1 || die "user '${TAP_USER}' does not exist."

# ---- create / converge ------------------------------------------------------
if ip link show "${IFACE}" >/dev/null 2>&1; then
  say "${IFACE} already exists — converging address/flags."
else
  ip tuntap add dev "${IFACE}" mode tap user "${TAP_USER}"
  say "created ${IFACE} (owner: ${TAP_USER})."
fi

ip addr replace "${CIDR}" dev "${IFACE}"
ip link set dev "${IFACE}" up multicast on
# The FVP hostbridge delivers the guest's DDS multicast/unicast frames to the
# host side only when the tap is promiscuous (demo/README.md).
ip link set dev "${IFACE}" promisc on

say "${IFACE} ready: $(ip -brief addr show "${IFACE}" | awk '{$1=$1};1')"
if [ "${IFACE}" != "tap0" ]; then
  warn "non-default interface — export FVP_TAP_INTERFACE=${IFACE} before ./build.sh --network tap."
fi
