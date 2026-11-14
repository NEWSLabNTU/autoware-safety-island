#!/usr/bin/env bash
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
#
# run-fvp-ci-local.sh — run the Zephyr FVP CI locally, detached, without
# destroying the build cache.
#
# Exists because three separate mistakes were made running that CI by hand,
# and each is cheap to encode and expensive to rediscover:
#
#   1. DO NOT WIPE THE BUILD ROOT. `rm -rf build/zephyr-fvp` before a run makes
#      all six variants build cold, including six separate `nros-rust` cargo
#      trees (~834 MB each). Nothing requires it: run-zephyr-fvp-ci.sh does not
#      clean, and build.sh only cleans behind `-c`. Pass --clean here if a
#      clean really is wanted.
#
#   2. `nohup ... &` FROM A TOOL-DRIVEN SHELL DOES NOT SURVIVE. The whole
#      process group is signalled when the caller is killed, so a CI run
#      started that way dies mid-phase and leaves its FVP orphaned. One such
#      orphan burned a core for ten hours. `setsid` puts the run in its own
#      session so it outlives the launcher.
#
#   3. DO NOT TEST LIVENESS WITH `pgrep -f run-zephyr-fvp-ci`. That pattern
#      matches the command line of the shell doing the checking, so it can
#      never report "finished". Use the pidfile this script writes.
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
LOG="${ROOT}/log/fvp-ci-local.log"
PIDFILE="${ROOT}/log/fvp-ci-local.pid"

CLEAN=0
[[ "${1:-}" == "--clean" ]] && { CLEAN=1; shift; }

case "${1:-run}" in
  status)
    if [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
      echo "running (pid $(cat "${PIDFILE}")), log: ${LOG}"
      tail -3 "${LOG}" 2>/dev/null
    else
      echo "not running"
      [[ -f "${LOG}" ]] && tail -3 "${LOG}"
    fi
    exit 0
    ;;
  stop)
    if [[ -f "${PIDFILE}" ]]; then
      # Kill the session group, so the model dies with the driver rather than
      # being orphaned.
      kill -TERM -- "-$(cat "${PIDFILE}")" 2>/dev/null || true
      sleep 2
      kill -KILL -- "-$(cat "${PIDFILE}")" 2>/dev/null || true
      rm -f "${PIDFILE}"
    fi
    # Sweep any model still holding this repo's ELFs. Matched on the build
    # path AND the ELF name: matching the path alone would also select
    # build.sh, west and cmake, and killing those mid-run is worse than the
    # orphan being swept.
    stray="$(ps -eo pid,args 2>/dev/null \
             | grep -F "${ROOT}/build/" | grep -F 'zephyr.elf' \
             | grep -v ' grep ' | awk '{print $1}')"
    [[ -n "${stray}" ]] && { echo "sweeping stray FVP: ${stray}"; kill -KILL ${stray} 2>/dev/null || true; }
    echo "stopped"
    exit 0
    ;;
esac

if [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
  echo "already running (pid $(cat "${PIDFILE}")). Use '$0 status' or '$0 stop'." >&2
  exit 1
fi

mkdir -p "${ROOT}/log"
if [[ "${CLEAN}" == "1" ]]; then
  echo "cleaning build/zephyr-fvp (this makes every variant build cold)"
  rm -rf "${ROOT}/build/zephyr-fvp"
fi

# Remove any stale pidfile FIRST. The wait loop below tests for a non-empty
# file, and a leftover from a previous run satisfies that instantly -- so the
# launcher would report the PREVIOUS run's pid, which is exactly the stale-read
# failure this pidfile exists to prevent.
rm -f "${PIDFILE}"

# The inner shell writes its OWN pid. `setsid ... & echo $!` records setsid's
# pid, and setsid forks then exits, so that value is dead on arrival -- which
# made `status` and `stop` silently useless the first time this was tested.
setsid bash -c "
  echo \$\$ > '${PIDFILE}'
  cd '${ROOT}'
  source ./activate-asi.sh
  exec .github/scripts/run-zephyr-fvp-ci.sh
" >"${LOG}" 2>&1 < /dev/null &

disown || true
# Give the child a moment to write it, rather than racing the first status call.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "${PIDFILE}" ]] && break
  sleep 0.2
done
echo "started pid $(cat "${PIDFILE}")"
echo "  log:    ${LOG}"
echo "  status: $0 status"
echo "  stop:   $0 stop"
