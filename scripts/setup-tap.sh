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
#   # pace the link to the emulated NIC's speed (an536 lane — see below)
#   sudo ./scripts/setup-tap.sh --iface tap1 --cidr 192.0.3.1/24 --rate 100mbit
#   sudo ./scripts/setup-tap.sh --iface tap1 --rate none    # remove pacing
#
# Verify with:  tc -s qdisc show dev tap1
#
# Idempotent: re-running converges to the requested state. If you use a
# non-default --iface, export FVP_TAP_INTERFACE=<iface> before ./build.sh so
# the generated FVP runner command names the same device.
#
# ---- Why --rate exists (nano-ros issue 0917) --------------------------------
# QEMU's tap backend hands frames to the guest as fast as the host can write
# them. It does NOT pace them to the speed of the NIC it is emulating, so the
# emulated board is HARSHER than the part it models, and a test lane that
# leaves it unpaced is not honest about the hardware.
#
# It matters on the an536 lane. The emulated LAN9118 is a 10/100 part with a
# 10,560-byte RX FIFO, and its driver has to start draining before that fills:
#
#     1440 B frame (1420 + preamble/IFG) at 100 Mbps   ->  115 us
#     usable FIFO 9024 B (10560 - 1536 headroom)       ->  6 frames
#     time to fill                                     ->  691 us
#     an 8-fragment RTPS burst (a ~10.5 KiB ROS topic) ->  922 us of wire
#
# Unpaced, all 8 frames land at once, the guest is never scheduled inside the
# burst, and no driver — polled or interrupt-driven — can keep up. Paced to
# 100 Mbps the budget is real: ~0.7 ms, which a 5 ms polled drain misses by 7x
# and an RX interrupt meets with room to spare. So pacing is what lets the lane
# tell a slow driver apart from an impossible one.
#
# `netem rate` rather than `tbf`: netem serialises each packet by its own
# transmission time, which is what a PHY does. TBF is a token bucket whose
# `burst` the kernel wants at roughly rate/HZ — about 12.5 KB at 100 Mbit,
# which is the whole RTPS burst, so it would let the burst through unpaced and
# leave the lane exactly where it started.

set -euo pipefail

say()  { echo -e "\033[0;32m[asi-tap]\033[0m $*"; }
warn() { echo -e "\033[0;33m[asi-tap]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[asi-tap]\033[0m $*" >&2; exit 1; }

# Keep the original argv: the root check below tells the operator to re-run
# under sudo, and the parse loop has shifted "$@" empty by then — so without
# this the suggested command silently drops --iface/--rate.
ORIG_ARGS=("$@")

IFACE="tap0"
CIDR="192.168.10.1/24"
TAP_USER="${SUDO_USER:-}"
DELETE=0
RATE=""


while [ $# -gt 0 ]; do
  case "$1" in
    --iface)  IFACE="${2:?--iface needs a value}"; shift 2 ;;
    --cidr)   CIDR="${2:?--cidr needs a value}"; shift 2 ;;
    --user)   TAP_USER="${2:?--user needs a value}"; shift 2 ;;
    --delete) DELETE=1; shift ;;
    --rate)   RATE="${2:?--rate needs a value (e.g. 100mbit, or none)}"; shift 2 ;;
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
  die "must run as root — e.g.: sudo $0 ${ORIG_ARGS[*]}"
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

# ---- link pacing ------------------------------------------------------------
# Shapes traffic LEAVING the host on this device, i.e. host -> guest, which is
# the direction that overruns the emulated NIC's receive FIFO.
if [ -n "${RATE}" ]; then
  command -v tc >/dev/null 2>&1 || die "tc not found — install iproute2 to use --rate."
  if [ "${RATE}" = "none" ] || [ "${RATE}" = "off" ]; then
    if tc qdisc del dev "${IFACE}" root 2>/dev/null; then
      say "removed link pacing on ${IFACE}."
    else
      say "no link pacing to remove on ${IFACE}."
    fi
  else
    # `replace` rather than `add` so re-running converges instead of failing
    # with "File exists".
    tc qdisc replace dev "${IFACE}" root netem rate "${RATE}" \
      || die "tc failed to pace ${IFACE} at ${RATE} (needs sch_netem)."
    say "paced ${IFACE}: $(tc qdisc show dev "${IFACE}" | head -1)"
  fi
fi

say "${IFACE} ready: $(ip -brief addr show "${IFACE}" | awk '{$1=$1};1')"
if [ "${IFACE}" != "tap0" ]; then
  warn "non-default interface — export FVP_TAP_INTERFACE=${IFACE} before ./build.sh --network tap."
fi
