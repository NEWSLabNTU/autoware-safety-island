#!/usr/bin/env bash
# Shared helpers for runtime CI phases.
# Each runtime workflow step sources this file once at the top.
#
# Usage:
#   source .github/scripts/ci-helpers.sh
#   run_with_timeout <binary> <log_path> <timeout_seconds>
#   run_command_with_timeout <log_path> <timeout_seconds> <command> [args...]
#   require_marker   <log_path> <fixed-string marker>
#   kill_with_timeout <pid> [grace_seconds]

set -euo pipefail

# SIGTERM grace period before timeout(1) / kill_with_timeout escalate to SIGKILL.
# Bounds every CI step's worst-case wall time so a blocked-on-SIGTERM binary
# cannot hang the runner.
CI_KILL_AFTER_SECONDS="${CI_KILL_AFTER_SECONDS:-5}"

# Put the image's ROS / Autoware library directories on LD_LIBRARY_PATH.
#
# Two different things in this repo need it, and both failed the same way:
#
#   actuation_posix_entry: error while loading shared libraries: libiceoryx_binding_c.so
#   cached idlc /opt/ros/humble/bin/idlc cannot run (... libiceoryx_binding_c.so ...)
#
# The first is the POSIX lane's own binary at run time; the second is a HOST
# tool the Zephyr lane shells during cmake configure. A linker or a package
# manager finding a library says nothing about the loader finding it.
#
# Both `lib` AND its multiarch subdirectory: these installs put the shared
# objects in lib/x86_64-linux-gnu, and a path carrying only `lib` looks right
# and still fails.
add_ros_lib_paths() {
  local p d
  for p in /opt/autoware /opt/autoware/*/ "/opt/ros/${ROS_DISTRO:-humble}" /opt/ros/*/; do
    for d in "${p}/lib" "${p}"/lib/*-linux-gnu; do
      [ -d "${d}" ] || continue
      case ":${LD_LIBRARY_PATH:-}:" in
        *":${d}:"*) ;;
        *) LD_LIBRARY_PATH="${d}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
      esac
    done
  done
  export LD_LIBRARY_PATH
}

dump_log() {
  local log="$1"
  if [ -f "$log" ]; then
    echo "----- log: $log -----"
    cat "$log"
    echo "----- end log -----"
  fi
}

# Run a command with a wall-clock timeout. Exit 0 (clean) and 124 (SIGTERM on
# timeout) are both considered success. GNU timeout may return 137 after
# --kill-after escalates to SIGKILL, so treat that as a bounded timeout too.
is_success_or_timeout() {
  local rc="$1"
  [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]
}

# Run a command with a wall-clock timeout. timeout(1) escalates to SIGKILL after
# CI_KILL_AFTER_SECONDS so a command that ignores SIGTERM still terminates.
# Non-timeout exits dump the log and fail.
run_command_with_timeout() {
  local log="$1"
  local secs="$2"
  shift 2

  rm -f "$log"
  set +e
  timeout --kill-after="${CI_KILL_AFTER_SECONDS}s" "${secs}s" "$@" >"$log" 2>&1
  local rc=$?
  set -e

  if ! is_success_or_timeout "$rc"; then
    dump_log "$log"
    echo "Unexpected exit status $rc from command: $*" >&2
    exit "$rc"
  fi
}

# Run a binary with a wall-clock timeout. Non-timeout exits dump the log and fail.
run_with_timeout() {
  local bin="$1"
  local log="$2"
  local secs="$3"

  if [ ! -x "$bin" ]; then
    echo "Missing or non-executable binary: $bin" >&2
    exit 1
  fi

  run_command_with_timeout "$log" "$secs" "$bin"
}

# Send SIGTERM to a backgrounded pid and wait up to `grace_seconds` (default
# CI_KILL_AFTER_SECONDS) for it to exit. If still alive after the grace window,
# escalate to SIGKILL. Always reaps the pid via `wait` so the step cannot hang
# on an unbounded `wait $pid`.
kill_with_timeout() {
  local pid="$1"
  local grace="${2:-$CI_KILL_AFTER_SECONDS}"

  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt "$grace" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Fail if the fixed-string marker is missing from the log.
require_marker() {
  local log="$1"
  local marker="$2"
  if ! grep -Fq -- "$marker" "$log"; then
    dump_log "$log"
    echo "Missing marker in $log: $marker" >&2
    exit 1
  fi
}

# Assert a marker is ABSENT. The runtime phases are long-running images killed
# by timeout, so a fatal error does not change the exit code and a
# require_marker-only phase stays green through a crash.
forbid_marker() {
  local log="$1"
  local marker="$2"
  if grep -Fq -- "$marker" "$log"; then
    dump_log "$log"
    echo "Forbidden marker present in $log: $marker" >&2
    exit 1
  fi
}

# Assert no thread's stack high-water exceeds a percentage of its allocation.
#
# Three separate stack overflows were found in this repo by reading the Layer 1
# report by eye — net_socket_service (1200 allocated, 2880 needed), main
# (16 KiB allocated, 153 KB needed) and asi_sntp_resync (4096 allocated, 7024
# needed). NONE printed a diagnostic: an overflow here corrupts whatever sits
# adjacent and the image either hangs silently or dies somewhere unrelated. The
# report is the only thing that makes them visible, so assert on it rather than
# relying on someone reading the artifact.
#
# A thread already AT 100 % is the dangerous case and reads as exactly 100:
# the analyzer clamps at the stack end, so the true requirement is unknown and
# may be far higher. Treat any breach as fatal and name the numbers.
#
#   require_stack_headroom <log> <max_percent>
require_stack_headroom() {
  local log="$1"
  local limit="$2"
  local rows breach unparsed

  # Format: " name : STACK: unused N usage U / T (P %); CPU: C %"
  #
  # Anchor the name capture on the " : STACK:" separator rather than taking a
  # single token: Zephyr's idle threads are named "idle 00" .. "idle 03", with
  # a space. The original single-token pattern never matched them, the line
  # then reached awk unsubstituted, and `$1 >= lim` compared the STRING "idle"
  # against "85" -- true, because 'i' sorts after '8'. Every healthy build
  # therefore failed this assertion with garbage field values. Normalise to a
  # fixed "OK <pct> <usage> <total> <name...>" shape so the numeric test can
  # never see a non-numeric field.
  rows=$(sed 's/\r$//' "$log" \
    | grep -a "STACK: unused" \
    | sed -E 's/^ *(.*[^ ]) *: STACK: unused [0-9]+ usage ([0-9]+) \/ ([0-9]+) \(([0-9]+) %\).*/OK \4 \2 \3 \1/')

  # Anything the pattern did not rewrite is an analyzer format this function
  # does not understand. Fail loudly instead of letting it fall through the
  # numeric test, which is exactly how the bug above stayed invisible.
  unparsed=$(printf '%s\n' "${rows}" | grep -av '^OK ' || true)
  if [ -n "${unparsed}" ]; then
    dump_log "$log"
    echo "Unrecognised thread-analyzer lines in $log:" >&2
    printf '%s\n' "${unparsed}" >&2
    exit 1
  fi

  breach=$(printf '%s\n' "${rows}" \
    | awk -v lim="$limit" '$2 + 0 >= lim + 0 {
        name = $5
        for (i = 6; i <= NF; i++) name = name " " $i
        printf "  %s: %s/%s bytes (%s%%)\n", name, $3, $4, $2
      }')

  if [ -n "${breach}" ]; then
    dump_log "$log"
    echo "Thread stack high-water at or above ${limit}% in $log:" >&2
    echo "${breach}" >&2
    echo "A thread at 100% is already overflowing — the analyzer clamps at the" >&2
    echo "stack end, so its real requirement is unknown. Raise the stack and" >&2
    echo "re-measure to find the true figure." >&2
    exit 1
  fi
}
