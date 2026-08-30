#!/usr/bin/env bash
# At what RATE does each topic actually reach the controller?
#
# The controller's log answers a boolean - "waiting for X", or silence - which
# cannot separate "arriving at 10 Hz" from "arrived once, a minute ago". Its
# freshness check is a rate test (0.5 s), so the rate has to be observable.
#
# Build with the counters in:
#   ASI_RX_COUNTERS=1 NROS_DOMAIN_ID=2 ./build.sh --platform freertos-an536
#
# Usage: [WINDOW=20] scripts/an536-rx-rate.sh [trajectory-points]
#
# This is the rig that mapped the an536 fragment cliff (nano-ros issue 0917).
# Published at 10 Hz, the trajectory reaches the app at:
#
#     1 fragment  (908 B)    2.6 Hz    fresh
#     4 fragments (5308 B)   2.5 Hz    fresh
#     5 fragments (6364 B)   2.1 Hz    fresh
#     6 fragments (7772 B)   0.8 Hz    STALE
#     7 fragments (9180 B)   0.0 Hz    STALE
#
# The emulated LAN9118's usable RX FIFO holds six 1440-byte frames, and that is
# exactly where the cliff sits. A reliable reader delivers IN ORDER, so one lost
# fragment stalls the stream until repair rather than letting a newer complete
# sample through - which is why this is a cliff and not a slope.

set -uo pipefail
ROOT=/home/aeon/repos/autoware-safety-island
SP="${TMPDIR:-/tmp}/asi-an536-rx"
mkdir -p "$SP"
QEMU_BIN=${QEMU_BIN:-$HOME/.nros/sdk/qemu/11.0.0-nros2/bin/qemu-system-arm}
ELF=$ROOT/build/freertos-an536/src/freertos_an536_entry/actuation_an536_entry
LOG=$SP/rt-island.log
POINTS=${1:-120}
WINDOW=${WINDOW:-20}

read_counters() {
  local out try
  # Retry: QEMU's stub takes one connection at a time and does not always free
  # it the instant a batch gdb exits, so a second read moments later can be
  # refused for reasons that have nothing to do with the guest. Detach
  # explicitly so the next attempt finds the stub free.
  for try in 1 2 3; do
    out=$(gdb-multiarch -q -batch -ex 'set arch arm' -ex 'set confirm off' -ex "file $ELF" \
          -ex 'target remote :1234' -x "$ROOT/scripts/an536-rx-counters.py" -ex 'detach' 2>&1)
    grep -qE '^asi_rx' <<<"$out" && break
    sleep 2
  done
  # A failed attach is NOT an error to gdb: it falls back to the ELF's static
  # initialisers and prints a confident set of zeros. Refuse to report those.
  if grep -qiE 'connection (timed out|refused)|no such file|cannot access' <<<"$out"; then
    echo "GDB-ATTACH-FAILED"
    return 1
  fi
  grep -E '^asi_rx' <<<"$out"
}

pkill -f "[q]emu-system-arm -machine mps3-an536"; pkill -f "[a]n536-sweep-pub.py"; sleep 1
ip link set tap1 up 2>/dev/null
pgrep -f "sntp-server.py --bind 192.0.3.1" >/dev/null || {
  nohup python3 $ROOT/scripts/sntp-server.py --bind 192.0.3.1 --port 12123 >/dev/null 2>&1 &
  disown $! 2>/dev/null; }
rm -f "$LOG"
nohup "$QEMU_BIN" -machine mps3-an536 -nographic \
  -semihosting-config enable=on,target=native -kernel "$ELF" \
  -net nic -net tap,ifname=tap1,script=no,downscript=no \
  -netdev hubport,id=h0,hubid=0 -gdb tcp::1234 > "$LOG" 2>&1 &
disown $! 2>/dev/null
for i in $(seq 1 150); do
  grep -q "Actuation Safety Island is Live" "$LOG" 2>/dev/null && break; sleep 1
done
grep -q "Actuation Safety Island is Live" "$LOG" || { echo "no boot"; exit 1; }

set +u; source /opt/ros/humble/setup.bash; set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=2
export CYCLONEDDS_URI="file://$ROOT/log/probe-cyclone.xml"
python3 "$ROOT/scripts/an536-sweep-pub.py" --small-only --with-trajectory "$POINTS" \
  > "$SP/rt-pub.log" 2>&1 &
disown $! 2>/dev/null

sleep 12
A=$(read_counters)
sleep "$WINDOW"
B=$(read_counters)
if grep -q GDB-ATTACH-FAILED <<<"$A$B"; then
  echo "SKIPPED: gdb could not attach to the running image, so the counters are"
  echo "         unreadable. Not reporting zeros — see scripts/an536-rx-counters.py."
  pkill -f "[a]n536-sweep-pub.py"; pkill -f "[q]emu-system-arm -machine mps3-an536"
  exit 3
fi
pkill -f "[a]n536-sweep-pub.py"

echo "publisher: small topics 40 Hz each, trajectory 10 Hz (${POINTS} pts)"
echo "window: ${WINDOW}s"
printf '%s\n' "$A" > "$SP/rt-a.txt"
printf '%s\n' "$B" > "$SP/rt-b.txt"
python3 - "$SP/rt-a.txt" "$SP/rt-b.txt" "$WINDOW" <<'PY'
import sys
def load(path):
    out = {}
    for line in open(path):
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = int(v.split()[0])
    return out
a, b, w = load(sys.argv[1]), load(sys.argv[2]), float(sys.argv[3])
for k in ("asi_rx_odom", "asi_rx_accel", "asi_rx_steer", "asi_rx_traj", "asi_rx_opmode"):
    if k in a and k in b:
        print("  %-14s %6d -> %6d   %6.1f Hz" % (k, a[k], b[k], (b[k] - a[k]) / w))
PY
echo "island still reports: $(grep -ao 'Waiting for [a-z ]*' "$LOG" | sort | uniq -c | tr '\n' ' ')"
pkill -f "[q]emu-system-arm -machine mps3-an536"
