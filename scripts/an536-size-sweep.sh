#!/usr/bin/env bash
# Issue 0836 rig: on a HEALTHY island, is there a payload-SIZE cliff?
#
# 0836 claimed the island receives every small topic and never the 13 KiB
# trajectory. It does not: the answer this produced is that every size from 116
# bytes to 17.6 KiB (13 RTPS fragments) arrives, and what actually broke was
# discovery — dropped SEDP frames left every topic announced after the gap
# unmatched (nano-ros MEMP_NUM_TCPIP_MSG_INPKT).
#
# The health gate below is why the answer is trustworthy. An island that lost
# discovery receives NOTHING, and sweeping on top of that reports "nothing
# arrives at any size" — a cliff at zero that looks exactly like the bug being
# tested for. So the sweep first publishes the small topics and requires the
# island to stop reporting them missing; only then does it walk the trajectory
# across the fragment boundary (~1400 B). A run that fails the gate is reported
# as SKIPPED, not as a data point.
#
# Usage: an536-size-sweep.sh [points...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT}/log"
ISLAND_ELF="${ROOT}/build/freertos-an536/src/freertos_an536_entry/actuation_an536_entry"
ISLAND_LOG="${LOG_DIR}/sweep-island.log"
TAP_IF="tap1"; TAP_HOST_IP="192.0.3.1"; SNTP_PORT="12123"
QEMU_BIN="${QEMU_BIN:-qemu-system-arm}"
URI="${LOG_DIR}/sweep-cyclone.xml"
DWELL="${DWELL:-12}"
PCAP="${PCAP:-}"
DC=""

SIZES=("$@")
[[ ${#SIZES[@]} -eq 0 ]] && SIZES=(10 16 20 60 120 160 200)

say() { echo -e "\033[0;36m[sweep]\033[0m $*"; }
die() { echo -e "\033[0;31m[sweep]\033[0m $*" >&2; exit 1; }

mkdir -p "${LOG_DIR}"
[[ -f "${ISLAND_ELF}" ]] || die "no image at ${ISLAND_ELF}"

cleanup() {
  pkill -f "[a]n536-sweep-pub.py" 2>/dev/null
  pkill -f "[q]emu-system-arm -machine mps3-an536" 2>/dev/null
  [[ -n "${DC}" ]] && kill "${DC}" 2>/dev/null
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
    --port "${SNTP_PORT}" > "${LOG_DIR}/sweep-sntp.log" 2>&1 &
  disown $! 2>/dev/null; }

say "booting island"
rm -f "${ISLAND_LOG}"
nohup "${QEMU_BIN}" -machine mps3-an536 -nographic \
  -semihosting-config enable=on,target=native -kernel "${ISLAND_ELF}" \
  -net nic -net tap,ifname="${TAP_IF}",script=no,downscript=no \
  -netdev hubport,id=h0,hubid=0 > "${ISLAND_LOG}" 2>&1 &
disown $! 2>/dev/null
for ((i = 0; i < 120; i++)); do
  grep -q "Actuation Safety Island is Live" "${ISLAND_LOG}" 2>/dev/null && break; sleep 1
done
grep -q "Actuation Safety Island is Live" "${ISLAND_LOG}" 2>/dev/null || die "island never booted"

if [[ -n "${PCAP}" ]]; then
  nohup dumpcap -i "${TAP_IF}" -w "${PCAP}" -q > /dev/null 2>&1 & DC=$!
  sleep 1
fi

set +u; source /opt/ros/humble/setup.bash; set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=2
export CYCLONEDDS_URI="file://${URI}"

python3 "${ROOT}/scripts/an536-sweep-pub.py" --small-only > "${LOG_DIR}/sweep-small.log" 2>&1 &
SMALL=$!

# ---- health gate ----
# The island must stop reporting the small topics missing. Each wait line is
# throttled to CONFIG_LOG_THROTTLE_RATE (3 s), so 8 s of quiet on a topic that
# is being published at 40 Hz means it is genuinely arriving.
say "health gate: waiting for the small topics to land…"
sleep 12
MARK="$(wc -l < "${ISLAND_LOG}")"
sleep 8
GATE="$(tail -n +$((MARK + 1)) "${ISLAND_LOG}")"
for t in acceleration odometry steering; do
  if grep -q "Waiting for ${t} data" <<<"${GATE}"; then
    echo
    echo "SKIPPED: island never received '${t}' — this run lost discovery,"
    echo "         so it can say nothing about payload size. Not a data point."
    exit 3
  fi
done
say "health gate PASSED — the island is receiving. Sweeping trajectory size."

printf '\n%-8s %-9s %-6s %-11s %s\n' points bytes frags delivered detail
for n in "${SIZES[@]}"; do
  MARK="$(wc -l < "${ISLAND_LOG}")"
  timeout $((DWELL + 8)) python3 "${ROOT}/scripts/an536-sweep-pub.py" \
    --points "$n" --seconds "${DWELL}" > "${LOG_DIR}/sweep-pub-${n}.log" 2>&1
  sleep 3
  BYTES="$(grep -o 'serialized=[0-9]*' "${LOG_DIR}/sweep-pub-${n}.log" | head -1 | cut -d= -f2)"
  FRAGS=$(( (${BYTES:-0} + 1399) / 1400 ))
  TAIL="$(tail -n +$((MARK + 1)) "${ISLAND_LOG}")"
  W="$(grep -c 'Waiting for trajectory data' <<<"${TAIL}")"
  F="$(grep -c 'Waiting for fresh trajectory data' <<<"${TAIL}")"
  # Health must still hold, or the size reading is meaningless.
  if grep -q 'Waiting for acceleration data' <<<"${TAIL}"; then
    printf '%-8s %-9s %-6s %-11s %s\n' "$n" "${BYTES:-?}" "$FRAGS" "VOID" "island lost its receive path mid-sweep"
    break
  fi
  if [[ "$W" -eq 0 && "$F" -eq 0 ]]; then D=yes; else D=NO; fi
  printf '%-8s %-9s %-6s %-11s %s\n' "$n" "${BYTES:-?}" "$FRAGS" "$D" "waits=$W stale=$F"
done

kill "${SMALL}" 2>/dev/null
echo
say "island log: ${ISLAND_LOG}"
