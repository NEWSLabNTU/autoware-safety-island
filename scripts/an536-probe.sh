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
QEMU_BIN="${QEMU_BIN:-qemu-system-arm}"

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
