#!/usr/bin/env bash
# FVP TAP UDP -> gateway -> vcan0. Exit 77 if tap/vcan cannot be set up.
#
# Run it with no password through scripts/run-in-netns.sh, which makes tap0
# and vcan0 in a container's own network namespace:
#
#   scripts/run-in-netns.sh --vcan --tap -- \
#     actuation_module/test/run-fvp-tap-tunnel.sh build/zephyr-fvp-tap-can
#
# The network comes from, in order:
#   1. a tap0 (and vcan0) already configured: used as found, no
#      CAP_NET_ADMIN needed (a tap owned by this user, 192.168.10.1/24, up;
#      what run-in-netns.sh --tap makes);
#   2. creating them (CAP_NET_ADMIN);
#   3. a private network namespace (`unshare -rn`, unprivileged user
#      namespaces): the script re-runs itself there with its own tap0 and
#      vcan0, so nothing on the host changes. FVP_TAP_NETNS=0 disables it.
#
# The model is started from the build dir's recorded run_armfvp command
# (`build.sh --run`), which needs neither west nor cmake.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/build/zephyr-fvp-tap-can}"
TAP="${FVP_TAP_INTERFACE:-tap0}"
IFACE="${VCAN_IFACE:-vcan0}"
TIMEOUT_SECONDS="${FVP_TAP_TIMEOUT_SECONDS:-120}"
# The collector starts before the model, so its deadline must
# outlive the FVP timeout to count commands emitted after a slow build or boot.
COLLECTOR_TIMEOUT_SECONDS=$((TIMEOUT_SECONDS + 30))

if [ ! -e /dev/net/tun ]; then
  echo "SKIP: /dev/net/tun is missing" >&2
  exit 77
fi

if [ ! -f "${BUILD_DIR}/zephyr/zephyr.elf" ]; then
  echo "Missing ELF: ${BUILD_DIR}/zephyr/zephyr.elf" >&2
  echo "Build first: ./build.sh --platform zephyr-fvp --network tap --can-output-test -d ${BUILD_DIR}" >&2
  exit 1
fi

TAP_HOST_ADDR="192.168.10.1/24"

# Re-run this script inside a private user + network namespace, where it holds
# CAP_NET_ADMIN over its own devices. Returns only when that is unavailable.
run_in_netns() {
  if [ "${FVP_TAP_IN_NETNS:-0}" = "1" ] || [ "${FVP_TAP_NETNS:-1}" = "0" ]; then
    return 0
  fi
  if ! unshare -rn true 2>/dev/null; then
    return 0
  fi
  echo "No usable ${TAP} on the host: running in a private network namespace"
  exec unshare -rn env FVP_TAP_IN_NETNS=1 "$0" "${BUILD_DIR}"
}

link_is_up() {
  ip -o link show "$1" 2>/dev/null | grep -q '<[^>]*\bUP\b'
}

tap_is_ready() {
  link_is_up "${TAP}" &&
    ip -o addr show dev "${TAP}" 2>/dev/null | grep -q "inet ${TAP_HOST_ADDR} "
}

setup_tap() {
  if tap_is_ready; then
    return 0
  fi
  if ! ip link show "${TAP}" >/dev/null 2>&1; then
    ip tuntap add dev "${TAP}" mode tap 2>/dev/null || return 1
  fi
  ip addr replace "${TAP_HOST_ADDR}" dev "${TAP}" 2>/dev/null &&
    ip link set dev "${TAP}" up 2>/dev/null
}

setup_vcan() {
  if ! ip link show "${IFACE}" >/dev/null 2>&1; then
    ip link add "${IFACE}" type vcan 2>/dev/null || return 1
  fi
  link_is_up "${IFACE}" || ip link set up "${IFACE}" 2>/dev/null
}

if [ "${FVP_TAP_IN_NETNS:-0}" = "1" ]; then
  ip link set lo up
fi
if ! setup_tap; then
  run_in_netns
  echo "SKIP: cannot set up ${TAP} (need a configured user-owned ${TAP}, CAP_NET_ADMIN, or user namespaces)" >&2
  exit 77
fi
if ! setup_vcan; then
  run_in_netns
  echo "SKIP: cannot set up ${IFACE} (need CAP_NET_ADMIN and the vcan module)" >&2
  exit 77
fi

accepted_file="$(mktemp)"
gateway_log="$(mktemp)"
fvp_log="$(mktemp)"
python3 "${ROOT_DIR}/demo/can_tunnel_bridge/gateway.py" \
  --bind 192.168.10.1 --port 5555 --interface "${IFACE}" \
  >"${gateway_log}" 2>&1 &
gateway_pid=$!

python3 - "${ROOT_DIR}" "${IFACE}" "${accepted_file}" "${COLLECTOR_TIMEOUT_SECONDS}" <<'PY' &
import os
import socket
import struct
import sys
import time

root, iface, out, collector_timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
sys.path.insert(0, os.path.join(root, "demo/can_carla_bridge"))
from decoder import ControlCommandDecoder, DecoderEvent

can_sock = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
can_sock.bind((iface,))
can_sock.settimeout(1.0)
fmt = struct.Struct("=IB3x8s")
decoder = ControlCommandDecoder()
accepted = 0
deadline = time.monotonic() + collector_timeout
while time.monotonic() < deadline:
    try:
        raw = can_sock.recv(16)
    except socket.timeout:
        continue
    can_id, dlc, data = fmt.unpack(raw)
    event = decoder.feed(can_id, data[:dlc], dlc, False, time.monotonic())
    if event == DecoderEvent.ACCEPTED:
        accepted += 1
        if accepted >= 1:
            break
with open(out, "w", encoding="utf-8") as handle:
    handle.write(str(accepted))
PY
collector_pid=$!

# FVP_TAP_LOG_DIR keeps the model console and the gateway log (CI's artifact).
cleanup() {
  kill "${gateway_pid}" "${collector_pid}" 2>/dev/null || true
  wait "${gateway_pid}" 2>/dev/null || true
  wait "${collector_pid}" 2>/dev/null || true
  if [ -n "${FVP_TAP_LOG_DIR:-}" ]; then
    mkdir -p "${FVP_TAP_LOG_DIR}"
    cp -f "${fvp_log}" "${FVP_TAP_LOG_DIR}/fvp_tap_tunnel.log" 2>/dev/null || true
    cp -f "${gateway_log}" "${FVP_TAP_LOG_DIR}/fvp_tap_gateway.log" 2>/dev/null || true
  fi
  rm -f "${accepted_file}" "${gateway_log}" "${fvp_log}"
}
trap cleanup EXIT

# The model does not exit after the test: stop it (timeout(1) leads its own
# process group) once the console says the test passed and the collector has
# its command, or let the timeout end it.
timeout --kill-after=5s "${TIMEOUT_SECONDS}s" \
  "${ROOT_DIR}/build.sh" --platform zephyr-fvp --run -d "${BUILD_DIR}" >"${fvp_log}" 2>&1 &
fvp_pid=$!
while kill -0 "${fvp_pid}" 2>/dev/null; do
  if grep -q "CAN output tests passed" "${fvp_log}" &&
     ! kill -0 "${collector_pid}" 2>/dev/null; then
    kill -TERM -- "-${fvp_pid}" 2>/dev/null || kill -TERM "${fvp_pid}" 2>/dev/null || true
    break
  fi
  sleep 1
done
set +e
wait "${fvp_pid}"
fvp_rc=$?
set -e
wait "${collector_pid}" 2>/dev/null || true

if ! grep -q "CAN output tests passed" "${fvp_log}"; then
  echo "FVP UART did not report CAN output tests passed" >&2
  cat "${fvp_log}" >&2
  cat "${gateway_log}" >&2
  exit 1
fi

accepted="$(cat "${accepted_file}" 2>/dev/null || echo 0)"
if [ "${accepted}" -lt 1 ]; then
  echo "gateway/vcan decoder received no accepted command" >&2
  cat "${gateway_log}" >&2
  cat "${fvp_log}" >&2
  exit 1
fi

echo "FVP TAP UDP tunnel roundtrip OK (${accepted} command(s))"
# 124/137: the timeout ended the model; 143: stopped above after the pass.
if [ "${fvp_rc}" != "0" ] && [ "${fvp_rc}" != "124" ] && [ "${fvp_rc}" != "137" ] &&
   [ "${fvp_rc}" != "143" ]; then
  echo "FVP exited ${fvp_rc}" >&2
  exit "${fvp_rc}"
fi
