#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# provision-nxp-freertos.sh — prepare the NXP FreeRTOS kernel + Cortex-R52
# GIC port for the nano-ros S32Z2 lane (phase-4 W5.b item 3).
#
# The NXP distribution (FreeRTOS_S32ZE, from the NXP Flexnet portal — see
# actuation_module/src/s32z2_board_glue/README.md) is NXP-licensed and never
# committed. This script stages a local PATCHED copy and prints the env the
# build needs:
#
#   1. copies the NXP kernel tree into build/nxp-freertos/ (never in-place:
#      the patch must not dirty the vendor download),
#   2. applies the MANDATORY correctness patch
#      actuation_module/src/s32z2_board_glue/vendor_patched/port.c.patch to the
#      GCC/ARM_CR52_GIC port (IRQ solicited-resume restored CPSR from
#      SPSR_irq, corrupting the Thumb bit when an IRQ lands mid-Thumb libm
#      — sin/atan2 in the controllers; hard fault on real load),
#   3. prints the FREERTOS_DIR / FREERTOS_PORT exports for build.sh.
#
# Usage:
#   FREERTOS_S32ZE_PATH=~/nxp/FreeRTOS_S32ZE_4.0.0/_jar/S32DS/software/PlatformSDK_S32ZE/FreeRTOS \
#     scripts/provision-nxp-freertos.sh
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SRC="${FREERTOS_S32ZE_PATH:-}"
DST="${ROOT}/build/nxp-freertos"
PATCH="${ROOT}/actuation_module/src/s32z2_board_glue/vendor_patched/port.c.patch"

if [ -z "${SRC}" ] || [ ! -d "${SRC}/Source" ]; then
  echo "FREERTOS_S32ZE_PATH must point at the NXP FreeRTOS distribution" >&2
  echo "(the directory containing Source/; see" >&2
  echo " actuation_module/src/s32z2_board_glue/README.md for the download)." >&2
  exit 1
fi
if [ ! -d "${SRC}/Source/portable/GCC/ARM_CR52_GIC" ]; then
  echo "No GCC/ARM_CR52_GIC port under ${SRC}/Source/portable — wrong tree?" >&2
  exit 1
fi

rm -rf "${DST}"
mkdir -p "$(dirname "${DST}")"
cp -r "${SRC}/Source" "${DST}"

( cd "${DST}/portable/GCC/ARM_CR52_GIC" && patch -p1 < "${PATCH}" )

echo "NXP FreeRTOS staged (patched) at ${DST}"
echo "Build the nano-ros S32Z2 lane with:"
echo "  export FREERTOS_DIR=${DST}"
echo "  export FREERTOS_PORT=GCC/ARM_CR52_GIC"
echo "  ./build.sh --platform freertos-s32z2 -d build/freertos-s32z2"
