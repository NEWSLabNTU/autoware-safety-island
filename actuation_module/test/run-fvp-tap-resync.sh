#!/usr/bin/env bash
# The SNTP re-sync check on the FVP tap controller (nano-ros issue 0758,
# part 2 of its acceptance; phase-15 P5): the fvp-tap image, with
# clock.sntp_resync_interval_ms > 0, while scripts/sntp-server.py steps its
# served time mid-run, and the stamp age measured at the island's own output.
#
#   scripts/run-in-netns.sh --tap -- \
#     actuation_module/test/run-fvp-tap-resync.sh build/zephyr-fvp-tap
#
# Needs a configured tap0 (192.168.10.1/24, user-owned: what
# scripts/run-in-netns.sh --tap makes) and a ROS 2 environment with rclpy,
# rmw_cyclonedds_cpp and autoware_control_msgs (STAMP_PROBE_SETUP, default
# /opt/autoware/setup.bash: the devcontainer's). The model is started from the
# build dir's recorded run_armfvp command (`build.sh --run`).
#
# Steps:
#   1. scripts/sntp-server.py on 192.168.10.1:12123, told to step its time by
#      RESYNC_STEP_SECONDS (default +1000 s) RESYNC_STEP_AFTER_SECONDS
#      (default 60 s) after its first answer, the island's boot exchange;
#   2. scripts/stamp-age-probe.py on domain 2, recording the receive time and
#      stamp of every /control/trajectory_follower/control_cmd (the island
#      publishes it every cycle, HOLD included, so it needs no input);
#   3. the model, until RESYNC_AFTER_STEP_SECONDS (default 60 s) have passed
#      since the step, or FVP_TAP_TIMEOUT_SECONDS (default 420 s).
#
# Stamp age = the server's clock at receipt (the host clock, plus the step
# once it applied) minus the stamp. Expectations (exit 1 when one fails):
#   - the console says "nros: SNTP re-sync every <interval> ms";
#   - the server answered at least twice before the step (re-syncs, not only
#     the boot exchange) and at least once after it;
#   - the stamps follow the step: every sample that carries the old offset
#     (age above half the step) arrives between the step and the first
#     post-step answer plus RESYNC_SETTLE_S (default 2 s), and samples on the
#     stepped clock follow it;
#   - outside that window no stamp is stale: no age above RESYNC_MAX_STALE_S
#     (default 1 s);
#   - no stamp is further ahead of the server than RESYNC_MAX_AHEAD_S, and no
#     stamp goes back by more than that (default twice the interval plus
#     1 s). The FVP runs its guest clock faster than real time (about 2x
#     while the island runs), and between two answers the island's wall clock
#     advances on that clock, so its stamps run ahead of the server until the
#     next answer puts them back: a sawtooth of about the interval times the
#     guest's excess rate. The summary reports the measured envelope.
#
# RESYNC_LOG_DIR keeps the console, the server log, the probe CSV and the
# summary (FVP_TAP_LOG_DIR is used when it is unset).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/build/zephyr-fvp-tap}"
TAP="${FVP_TAP_INTERFACE:-tap0}"
TIMEOUT_SECONDS="${FVP_TAP_TIMEOUT_SECONDS:-420}"
STEP_SECONDS="${RESYNC_STEP_SECONDS:-1000}"
STEP_AFTER="${RESYNC_STEP_AFTER_SECONDS:-60}"
AFTER_STEP="${RESYNC_AFTER_STEP_SECONDS:-60}"
MAX_STALE="${RESYNC_MAX_STALE_S:-1.0}"
SETTLE="${RESYNC_SETTLE_S:-2}"
PROBE_SETUP="${STAMP_PROBE_SETUP:-/opt/autoware/setup.bash}"
LOG_DIR="${RESYNC_LOG_DIR:-${FVP_TAP_LOG_DIR:-}}"

if [ ! -f "${BUILD_DIR}/zephyr/zephyr.elf" ]; then
  echo "Missing ELF: ${BUILD_DIR}/zephyr/zephyr.elf" >&2
  echo "Build first: ./build.sh --platform zephyr-fvp --network tap -d ${BUILD_DIR}" >&2
  exit 1
fi
if ! ip -o addr show dev "${TAP}" 2>/dev/null | grep -q "inet 192.168.10.1/24 "; then
  echo "SKIP: no configured ${TAP} (run under scripts/run-in-netns.sh --tap)" >&2
  exit 77
fi
if [ ! -f "${PROBE_SETUP}" ]; then
  echo "SKIP: no ROS 2 environment at ${PROBE_SETUP} (STAMP_PROBE_SETUP)" >&2
  exit 77
fi

# The interval the image was built with, from its generated Kconfig.
interval_ms="$(sed -n 's/^CONFIG_NROS_CLOCK_SNTP_RESYNC_INTERVAL_MS=//p' \
  "${BUILD_DIR}/zephyr/.config" 2>/dev/null || true)"
if [ -z "${interval_ms}" ] || [ "${interval_ms}" = "0" ]; then
  echo "${BUILD_DIR} was built with clock.sntp_resync_interval_ms = ${interval_ms:-unset}: nothing to check" >&2
  exit 1
fi
MAX_AHEAD="${RESYNC_MAX_AHEAD_S:-$((2 * interval_ms / 1000 + 1))}"

work="$(mktemp -d)"
fvp_log="${work}/fvp_tap_resync.log"
sntp_log="${work}/sntp_server.log"
probe_log="${work}/stamp_probe.log"
probe_csv="${work}/stamp_age.csv"
summary="${work}/resync_summary.txt"
: >"${fvp_log}"

python3 "${ROOT_DIR}/scripts/sntp-server.py" --bind 192.168.10.1 --port 12123 \
  --step-seconds "${STEP_SECONDS}" --step-after-seconds "${STEP_AFTER}" \
  >"${sntp_log}" 2>&1 &
sntp_pid=$!

cat >"${work}/cyclonedds.xml" <<XML
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <General>
      <Interfaces><NetworkInterface name="${TAP}"/></Interfaces>
      <MaxMessageSize>1400B</MaxMessageSize>
    </General>
  </Domain>
</CycloneDDS>
XML
probe_seconds=$((TIMEOUT_SECONDS + 30))
(
  set +eu
  # shellcheck disable=SC1090
  . "${PROBE_SETUP}"
  export ROS_DOMAIN_ID=2 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
  export CYCLONEDDS_URI="file://${work}/cyclonedds.xml"
  exec python3 "${ROOT_DIR}/scripts/stamp-age-probe.py" --out "${probe_csv}" \
    --seconds "${probe_seconds}"
) >"${probe_log}" 2>&1 &
probe_pid=$!

cleanup() {
  kill "${sntp_pid}" "${probe_pid}" 2>/dev/null || true
  wait "${sntp_pid}" 2>/dev/null || true
  wait "${probe_pid}" 2>/dev/null || true
  if [ -n "${LOG_DIR}" ]; then
    mkdir -p "${LOG_DIR}"
    cp -f "${fvp_log}" "${sntp_log}" "${probe_log}" "${probe_csv}" "${summary}" \
      "${LOG_DIR}/" 2>/dev/null || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

timeout --kill-after=5s "${TIMEOUT_SECONDS}s" \
  "${ROOT_DIR}/build.sh" --platform zephyr-fvp --run -d "${BUILD_DIR}" >"${fvp_log}" 2>&1 &
fvp_pid=$!

# Run until AFTER_STEP seconds of host time have passed since the step.
stepped_at=""
while kill -0 "${fvp_pid}" 2>/dev/null; do
  if [ -z "${stepped_at}" ] && grep -q "sntp-server: stepped" "${sntp_log}"; then
    stepped_at="$(date +%s)"
  fi
  if [ -n "${stepped_at}" ] && [ $(($(date +%s) - stepped_at)) -ge "${AFTER_STEP}" ]; then
    kill -TERM -- "-${fvp_pid}" 2>/dev/null || kill -TERM "${fvp_pid}" 2>/dev/null || true
    break
  fi
  sleep 1
done
set +e
wait "${fvp_pid}"
fvp_rc=$?
set -e
kill "${probe_pid}" 2>/dev/null || true
wait "${probe_pid}" 2>/dev/null || true

set +e
python3 - "${fvp_log}" "${sntp_log}" "${probe_csv}" "${interval_ms}" "${MAX_STALE}" \
  "${MAX_AHEAD}" "${SETTLE}" "${STEP_SECONDS}" <<'PY' | tee "${summary}"
import re
import sys

fvp_log, sntp_log, csv_path = sys.argv[1:4]
interval_s = int(sys.argv[4]) / 1000.0
max_stale, max_ahead, settle, step_s = (float(v) for v in sys.argv[5:9])
fails = []

console = open(fvp_log, encoding="utf-8", errors="replace").read()
for pat in (r"nros: SNTP re-sync[^\n]*", r"nros: wall clock from[^\n]*",
            r"Stamp clock:[^\n]*"):
    for line in re.findall(pat, console):
        print(f"console: {line.strip()}")
if f"nros: SNTP re-sync every {int(interval_s * 1000)} ms" not in console:
    fails.append("no 'nros: SNTP re-sync every' line in the console")

answers, step_at = [], None
for line in open(sntp_log, encoding="utf-8"):
    m = re.search(r"answered \S+ at host time ([0-9.]+)", line)
    if m:
        answers.append(float(m.group(1)))
    m = re.search(r"stepped \S+ s .* at host time ([0-9.]+)", line)
    if m:
        step_at = float(m.group(1))
if step_at is None:
    fails.append("the server never stepped (the island never answered?)")
    step_at = float("inf")
before = [a for a in answers if a < step_at]
after = [a for a in answers if a >= step_at]
gaps = [b - a for a, b in zip(answers, answers[1:])]
print(f"server: {len(answers)} answers, {len(before)} before the step, "
      f"{len(after)} after; host-time gaps between answers: "
      + ", ".join(f"{g:.1f}" for g in gaps) + " s")
if len(before) < 2:
    fails.append(f"only {len(before)} answer(s) before the step: no re-sync ran")
if not after:
    fails.append("no answer after the step: the island never re-queried")

rows = []
with open(csv_path, encoding="utf-8") as handle:
    next(handle, None)
    for line in handle:
        recv, stamp = (float(v) for v in line.split(","))
        server = recv + (step_s if recv >= step_at else 0.0)
        rows.append((recv, stamp, server - stamp))
print(f"probe: {len(rows)} samples")
if not rows:
    fails.append("the probe received no control_cmd")


def describe(name, ages):
    if not ages:
        print(f"{name}: no samples")
        return
    s = sorted(ages)
    pick = lambda q: s[min(len(s) - 1, int(q * len(s)))]
    print(f"{name}: n={len(s)} min={s[0]*1e3:.1f} ms p50={pick(0.5)*1e3:.1f} ms "
          f"p99={pick(0.99)*1e3:.1f} ms max={s[-1]*1e3:.1f} ms")


pre = [a for r, _, a in rows if r < step_at]
resync_at = after[0] if after else float("inf")
window_end = resync_at + settle
post = [a for r, _, a in rows if r >= window_end]
stale = [r for r, _, a in rows if a > step_s / 2]
describe("age before the step", pre)
describe("age after the step window", post)
if stale:
    print(f"step window: {len(stale)} samples carried the old offset, "
          f"{stale[0] - step_at:.2f} s to {stale[-1] - step_at:.2f} s after the step; "
          f"first post-step answer {resync_at - step_at:.2f} s after the step")
first_new = next((r for r, _, a in rows if r >= step_at and a <= max_stale), None)
if first_new is not None:
    print(f"first stamp on the stepped clock: {first_new - step_at:.2f} s after the step, "
          f"{first_new - resync_at:+.2f} s from the first post-step answer")

if any(r < step_at or r >= window_end for r in stale):
    fails.append("a stamp carried the old offset outside the step window")
if first_new is None:
    fails.append("no stamp followed the step")
if not post:
    fails.append("no samples after the step window")
outside = [a for r, _, a in rows if r < step_at or r >= window_end]
if any(a > max_stale for a in outside):
    fails.append(f"a stamp outside the step window is older than {max_stale} s")
if any(a < -max_ahead for _, _, a in rows):
    fails.append(f"a stamp ran ahead of the server by more than {max_ahead} s")
back = [p[1] - c[1] for p, c in zip(rows, rows[1:]) if c[1] < p[1]]
if back:
    print(f"stamps went back {len(back)} time(s), at most {max(back):.2f} s "
          f"(the re-syncs taking the guest's excess back)")
if any(b > max_ahead for b in back):
    fails.append(f"a stamp went back by more than {max_ahead} s")

for f in fails:
    print(f"FAIL: {f}")
print("SNTP re-sync check " + ("FAILED" if fails else "OK"))
sys.exit(1 if fails else 0)
PY
check_rc=${PIPESTATUS[0]}
set -e

if [ "${check_rc}" != "0" ]; then
  echo "--- model console (tail) ---" >&2
  tail -n 80 "${fvp_log}" >&2
  echo "--- sntp server ---" >&2
  tail -n 40 "${sntp_log}" >&2
  echo "--- probe ---" >&2
  cat "${probe_log}" >&2
  exit 1
fi
# 124/137: the timeout ended the model; 143: stopped above.
if [ "${fvp_rc}" != "0" ] && [ "${fvp_rc}" != "124" ] && [ "${fvp_rc}" != "137" ] &&
   [ "${fvp_rc}" != "143" ]; then
  echo "FVP exited ${fvp_rc}" >&2
  exit "${fvp_rc}"
fi
echo "FVP TAP SNTP re-sync OK"
