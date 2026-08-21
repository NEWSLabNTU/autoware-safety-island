#!/usr/bin/env bash
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
#
# capture-fvp-trace.sh — build the Zephyr FVP image with CTF tracing, run it
# on the model for a bounded window, and decode the captured stream into a
# task timeline + scheduling statistics.
#
# See docs/design/rt_evaluation_zephyr.rst for what the trace contains and the
# caveats that bound it (32-bit ns timestamps wrap at ~4.29 s; the tracing
# buffer is irq_lock-protected, so this is valid only on the CONFIG_SMP=n image
# the FVP lane builds).
#
# Usage: scripts/capture-fvp-trace.sh [-d BUILD_DIR] [-s SECONDS] [--no-build]
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BUILD_DIR="${ROOT}/build/zephyr-fvp-trace"
RUN_SECONDS=25
DO_BUILD=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) BUILD_DIR="$2"; shift 2 ;;
    -s) RUN_SECONDS="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say() { echo -e "\033[0;32m[capture]\033[0m $*"; }
die() { echo -e "\033[0;31m[capture]\033[0m $*" >&2; exit 1; }

# activate-asi.sh carries ZEPHYR_BASE / ZEPHYR_SDK_INSTALL_DIR / the nros CLI
# on PATH; bootstrap-asi.sh writes it. Sourcing here keeps the script usable
# from a bare shell.
if [ -f "${ROOT}/activate-asi.sh" ]; then
  # shellcheck disable=SC1091
  source "${ROOT}/activate-asi.sh"
fi

# The model is license-gated and lives outside the tree; tools/README.md
# documents the tools/fvp layout that bootstrap-asi.sh exports from.
if [ -z "${ARMFVP_BIN_PATH:-}" ]; then
  for candidate in "${ROOT}"/tools/fvp/*/bin; do
    if [ -x "${candidate}/FVP_BaseR_AEMv8R" ]; then
      export ARMFVP_BIN_PATH="${candidate}"
      break
    fi
  done
fi
[ -x "${ARMFVP_BIN_PATH:-/nonexistent}/FVP_BaseR_AEMv8R" ] || \
  die "FVP model not found — set ARMFVP_BIN_PATH or extract it under tools/fvp/."
say "FVP: $("${ARMFVP_BIN_PATH}/FVP_BaseR_AEMv8R" --version | head -1)"

TRACE_FILE="${BUILD_DIR}/trace.ctf"
CONSOLE_LOG="${BUILD_DIR}/console.log"
mkdir -p "${BUILD_DIR}"

if [ "${DO_BUILD}" = "1" ]; then
  say "building with --trace (CTF -> uart1) …"
  # TRACE_OUT_FILE is read by build.sh; it bakes the uart1 redirect into the
  # `run` target at CMake configure time via ARMFVP_EXTRA_FLAGS.
  TRACE_OUT_FILE="${TRACE_FILE}" \
    "${ROOT}/build.sh" --platform zephyr-fvp --trace -d "${BUILD_DIR}"
fi

[ -f "${BUILD_DIR}/zephyr/zephyr.elf" ] || die "no ELF at ${BUILD_DIR}/zephyr/zephyr.elf"

# Start clean: the RAM/UART stream is append-only from the model's side, and a
# stale file would silently be parsed as part of this run.
rm -f "${TRACE_FILE}" "${CONSOLE_LOG}"

say "running FVP for ${RUN_SECONDS}s …"
set +e
timeout --signal=INT --kill-after=10s "${RUN_SECONDS}" \
  west build -d "${BUILD_DIR}" --target run > "${CONSOLE_LOG}" 2>&1
rc=$?
set -e
# 124 = timeout fired, which is the normal path: the controller never exits.
if [ "${rc}" != "0" ] && [ "${rc}" != "124" ]; then
  say "FVP exited rc=${rc}; console tail:"
  tail -20 "${CONSOLE_LOG}" >&2
fi

[ -s "${CONSOLE_LOG}" ] || die "FVP produced no console output — see ${CONSOLE_LOG}"
say "console: ${CONSOLE_LOG} ($(wc -l < "${CONSOLE_LOG}") lines)"

[ -s "${TRACE_FILE}" ] || die "no trace captured at ${TRACE_FILE} (is uart1 redirected?)"
say "trace:   ${TRACE_FILE} ($(stat -c %s "${TRACE_FILE}") bytes)"

say "decoding …"
"${ROOT}/scripts/parse-zephyr-ctf.py" "${TRACE_FILE}" \
  -m "${ROOT}/zephyr/subsys/tracing/ctf/tsdl/metadata" --stats \
  | tee "${BUILD_DIR}/trace-stats.txt"

say "done. timeline: scripts/parse-zephyr-ctf.py ${TRACE_FILE} --timeline --limit 200"
