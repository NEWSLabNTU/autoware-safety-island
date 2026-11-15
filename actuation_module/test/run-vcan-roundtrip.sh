#!/usr/bin/env bash
# SocketCAN vcan0 roundtrip (classic + CAN-FD). Exit 77 if vcan cannot be created.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-}"

if [ -z "${BIN}" ]; then
  for candidate in \
    "${ROOT_DIR}/build/freertos-posix-can/can_vcan_sender" \
    "${ROOT_DIR}/build/freertos-posix/can_vcan_sender"
  do
    if [ -x "${candidate}" ]; then
      BIN="${candidate}"
      break
    fi
  done
fi

if [ -z "${BIN}" ] || [ ! -x "${BIN}" ]; then
  echo "can_vcan_sender not found. Build first:" >&2
  echo "  ./build.sh --platform freertos-posix --can-output-test -d build/freertos-posix-can" >&2
  exit 1
fi

# The test changes vcan0's MTU, which needs CAP_NET_ADMIN over it. Without
# that on the host, re-run in a private user + network namespace
# (`unshare -rn`, unprivileged user namespaces) with a vcan0 of its own; the
# host's vcan0 is left alone. VCAN_NETNS=0 disables it.
run_in_netns() {
  if [ "${VCAN_IN_NETNS:-0}" = "1" ] || [ "${VCAN_NETNS:-1}" = "0" ]; then
    return 0
  fi
  if unshare -rn true 2>/dev/null; then
    echo "No CAP_NET_ADMIN over vcan0: running in a private network namespace"
    exec unshare -rn env VCAN_IN_NETNS=1 "$0" "${BIN}"
  fi
}

setup_vcan() {
  if ! ip link show vcan0 >/dev/null 2>&1; then
    if ! ip link add vcan0 type vcan 2>/dev/null; then
      run_in_netns
      echo "SKIP: cannot create vcan0 (need CAP_NET_ADMIN and the vcan module)" >&2
      exit 77
    fi
  fi
  # The kernel rejects vcan MTU changes while the link is up, so set it down
  # first; CAN-FD needs the FD MTU, classic frames work at either size.
  if ! ip link set dev vcan0 down >/dev/null 2>&1; then
    run_in_netns
  fi
  if ! ip link set dev vcan0 mtu 72 >/dev/null 2>&1; then
    echo "SKIP: cannot set vcan0 MTU to 72 (need CAP_NET_ADMIN)" >&2
    exit 77
  fi
  if ! ip link set up vcan0 2>/dev/null; then
    echo "SKIP: cannot bring vcan0 up (need CAP_NET_ADMIN)" >&2
    exit 77
  fi
}

setup_vcan
python3 "${ROOT_DIR}/demo/can_carla_bridge/test_vcan_roundtrip.py" "${BIN}"

# CAN-FD must fail closed on an interface below the FD MTU.
if ! ip link set dev vcan0 down 2>/dev/null ||
  ! ip link set dev vcan0 mtu 16 2>/dev/null ||
  ! ip link set up vcan0 2>/dev/null; then
  echo "SKIP: cannot set vcan0 MTU to 16 (need CAP_NET_ADMIN)" >&2
  exit 77
fi
set +e
"${BIN}" expect-fd-init-failure
fd_rc=$?
set -e
ip link set dev vcan0 down >/dev/null 2>&1 || true
ip link set dev vcan0 mtu 72 >/dev/null 2>&1 || true
ip link set up vcan0 >/dev/null 2>&1 || true
if [ "${fd_rc}" != "0" ]; then
  echo "CAN-FD init did not fail closed on a low-MTU vcan0" >&2
  exit "${fd_rc}"
fi
echo "low-MTU CAN-FD fail-closed OK"
