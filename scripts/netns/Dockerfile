# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# The helper image scripts/run-in-netns.sh runs the network tests in. It
# carries no build: the host's binaries and the FVP install are bind-mounted.
# Ubuntu 22.04, the host release the binaries are built on (same glibc).
#
#   iproute2     ip link / ip tuntap / ip addr for vcan0 and tap0
#   python3      the CAN decoder, the UDP tunnel gateway and the test drivers
#   can-utils    cansend / candump for checking a bus by hand
#   libatomic1   the FVP model links it from the system
#   util-linux   setpriv, to run a test as the calling user after setup
FROM ubuntu:22.04

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      iproute2 python3 can-utils libatomic1 util-linux procps ca-certificates \
 && rm -rf /var/lib/apt/lists/*
