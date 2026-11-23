#!/usr/bin/env bash
# SocketCAN vcan roundtrip (phase-15 P7): the island's CAN output encoder,
# through nano-ros's SocketCAN backend of <nros/platform_can.h>, sends classic
# and CAN-FD frames on vcan0 and a SocketCAN receiver decodes them back; then
# the host UDP tunnel gateway puts a tunnelled batch on vcan0 and the decoder
# accepts it. The build runs here; the tests run in a network namespace of
# their own (scripts/run-in-netns.sh): a docker container with NET_ADMIN on a
# dev box, the job container on CI (ASI_NETNS_DIRECT=1). No sudo, no
# password, and the host's own vcan0 is never touched.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_ROOT="${ROOT_DIR}/build/freertos-posix-can"

source "${ROOT_DIR}/.github/scripts/ci-helpers.sh"

cd "${ROOT_DIR}"
source_ament_env

echo "FreeRTOS POSIX SocketCAN vcan roundtrip (classic + CAN-FD)"
# --can-output-test on this lane builds the controller image and, beside it,
# the can_vcan_sender host program (SocketCAN backend).
"${ROOT_DIR}/build.sh" --platform freertos-posix -d "${BUILD_ROOT}" \
  --can-output-test

# Both roundtrips run as root in a network namespace of their own with a
# vcan0 made inside it (scripts/run-in-netns.sh): the vcan roundtrip changes
# vcan0's MTU (the CAN-FD fail-closed check), which needs CAP_NET_ADMIN over
# it.
echo "SocketCAN vcan roundtrip + UDP tunnel gateway -> vcan roundtrip (vcan0 in a network namespace of its own)"
"${ROOT_DIR}/scripts/run-in-netns.sh" --vcan --root -- bash -c '
  set -e
  actuation_module/test/run-vcan-roundtrip.sh "$1"
  echo "vcan roundtrip OK"
  actuation_module/test/run-udp-tunnel-roundtrip.sh
  echo "UDP tunnel vcan roundtrip OK"
' run-vcan "${BUILD_ROOT}/can_vcan_sender"
