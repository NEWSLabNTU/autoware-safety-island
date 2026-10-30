#!/usr/bin/env bash
# Issue 0836 probe: boot the an536 island, drive it from ONE host publisher for
# a fixed window, and report what the island says it received.
#
# `--small-only` runs the control arm (topics known to arrive); `--points N`
# adds a Trajectory of N points on top. Comparing the two arms is the whole
# point — a crash or a stall that appears in BOTH is not about payload size.
#
# Usage: an536-probe.sh [--points N] [--secs S] [--tag NAME]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT}/log"
ISLAND_ELF="${ROOT}/build/freertos-an536/src/freertos_an536_entry/actuation_an536_entry"
TAP_IF="tap1"; TAP_HOST_IP="192.0.3.1"; SNTP_PORT="12123"
# QEMU: the nano-ros SDK build FIRST, then $PATH.
#
# These are not interchangeable. The SDK dist (`nros setup --tool qemu`) is a
# patched fork; upstream QEMU on $PATH is a different emulator with a different
# LAN9118 model, and this rig measures packet loss inside that model. Silently
# falling back to $PATH means measuring a machine the product never runs on —
# scripts/run-tap-demo.sh already resolves it this way, so a rig that does not
# is not measuring the demo's lane.
QEMU_BIN="${QEMU_BIN:-${NROS_HOME:-${HOME}/.nros}/sdk/qemu/11.0.0-nros2/bin/qemu-system-arm}"
if [[ ! -x "${QEMU_BIN}" ]]; then
  QEMU_BIN="$(command -v qemu-system-arm || true)"
  echo "WARNING: SDK qemu not found, falling back to ${QEMU_BIN:-<none>}." >&2
  echo "         Run: (cd modules/nros && nros setup --tool qemu)" >&2
fi
[[ -x "${QEMU_BIN}" ]] || { echo "no qemu-system-arm" >&2; exit 1; }

POINTS=0; SECS=60; TAG="probe"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --points) POINTS="$2"; shift 2 ;;
    --secs)   SECS="$2";   shift 2 ;;
    --tag)    TAG="$2";    shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
ISLAND_LOG="${LOG_DIR}/${TAG}-island.log"
URI="${LOG_DIR}/probe-cyclone.xml"

say() { echo -e "\033[0;36m[probe]\033[0m $*"; }
mkdir -p "${LOG_DIR}"

cleanup() {
  pkill -f "[a]n536-sweep-pub.py" 2>/dev/null
  pkill -f "[q]emu-system-arm -machine mps3-an536" 2>/dev/null
}
trap cleanup EXIT
cleanup; sleep 1

cat > "${URI}" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="2">
    <General>
      <AllowMulticast>spdp</AllowMulticast>
      <MaxMessageSize>1400B</MaxMessageSize>
      <Interfaces>
        <NetworkInterface autodetermine="false" priority="default" multicast="default" name="${TAP_IF}"/>
      </Interfaces>
    </General>
    <Sizing>
      <ReceiveBufferSize>16384B</ReceiveBufferSize>
      <ReceiveBufferChunkSize>2048B</ReceiveBufferChunkSize>
    </Sizing>
    <Discovery><ParticipantIndex>none</ParticipantIndex></Discovery>
  </Domain>
</CycloneDDS>
XML

ip link set "${TAP_IF}" up 2>/dev/null
pgrep -f "sntp-server.py --bind ${TAP_HOST_IP}" >/dev/null 2>&1 || {
  nohup python3 "${ROOT}/scripts/sntp-server.py" --bind "${TAP_HOST_IP}" \
    --port "${SNTP_PORT}" > "${LOG_DIR}/probe-sntp.log" 2>&1 &
  disown $! 2>/dev/null
}

# Is the link paced to the emulated NIC's speed? Unpaced, QEMU hands the guest
# a burst faster than the modelled 100 Mbps PHY ever could, so a receive-path
# result is about the emulator rather than the part (nano-ros issue 0917).
# Report it rather than enforce it — pacing needs root:
#   sudo scripts/setup-tap.sh --iface tap1 --cidr 192.0.3.1/24 --rate 100mbit
if command -v tc >/dev/null 2>&1; then
  if tc qdisc show dev "${TAP_IF}" 2>/dev/null | head -1 | grep -q netem; then
    echo "[link] ${TAP_IF} is PACED: $(tc qdisc show dev "${TAP_IF}" | head -1)"
  else
    echo "[link] ${TAP_IF} is UNPACED — bursts arrive faster than a 100 Mbps PHY;" >&2
    echo "       receive-path numbers from this run describe the emulator, not the NIC." >&2
  fi
fi

say "booting island → ${ISLAND_LOG}"
rm -f "${ISLAND_LOG}"
nohup "${QEMU_BIN}" -machine mps3-an536 -nographic \
  -semihosting-config enable=on,target=native -kernel "${ISLAND_ELF}" \
  -net nic -net tap,ifname="${TAP_IF}",script=no,downscript=no \
  -netdev hubport,id=h0,hubid=0 > "${ISLAND_LOG}" 2>&1 &
disown $! 2>/dev/null

for ((i = 0; i < 120; i++)); do
  grep -q "Actuation Safety Island is Live" "${ISLAND_LOG}" 2>/dev/null && break
  sleep 1
done
grep -q "Actuation Safety Island is Live" "${ISLAND_LOG}" 2>/dev/null || {
  echo "island never booted"; tail -5 "${ISLAND_LOG}"; exit 1; }
say "island live"

set +u; source /opt/ros/humble/setup.bash; set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=2
export CYCLONEDDS_URI="file://${URI}"

python3 "${ROOT}/scripts/an536-sweep-pub.py" --small-only > "${LOG_DIR}/${TAG}-small.log" 2>&1 &
SMALL=$!
if [[ "${POINTS}" -gt 0 ]]; then
  python3 "${ROOT}/scripts/an536-sweep-pub.py" --points "${POINTS}" --seconds "${SECS}" \
    > "${LOG_DIR}/${TAG}-traj.log" 2>&1 &
  TRAJ=$!
fi

# Run the observer mid-window, while the publishers are live: it answers
# "does island→host work" and "were the island's readers ever matched", which
# is what separates a broken rig from a broken receive path.
sleep 15
python3 "${ROOT}/scripts/an536-observer.py" > "${LOG_DIR}/${TAG}-obs.log" 2>&1
REMAIN=$(( SECS > 45 ? SECS - 45 : 5 ))
sleep "${REMAIN}"
kill "${SMALL}" ${TRAJ:-} 2>/dev/null

echo
echo "=== observer (host side) ==="
cat "${LOG_DIR}/${TAG}-obs.log" 2>/dev/null
echo "=== island: what it says it is still waiting for ==="
grep -ao "Waiting for [a-z ]*" "${ISLAND_LOG}" | sort | uniq -c
echo "=== island: liveness / faults ==="
grep -aE "ASSERT|FATAL|STACK OVERFLOW|error|Live" "${ISLAND_LOG}" | tail -5
[[ "${POINTS}" -gt 0 ]] && { echo "=== trajectory publisher ==="; cat "${LOG_DIR}/${TAG}-traj.log"; }
echo "=== island log lines: $(wc -l < "${ISLAND_LOG}") ==="
