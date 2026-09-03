#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# provision-orin-spe-bsp.sh — stage NVIDIA's SPE FreeRTOS BSP (and, optionally,
# the ARM bare-metal toolchain it needs) for the Jetson AGX Orin SPE lane
# (phase-10).
#
# The SPE is the Sensor Processing Engine: a Cortex-R5 in Orin's always-on
# power domain, running an NVIDIA-supplied FreeRTOS V10.4.3 firmware support
# package. It is the only Orin core that accepts our code — the Functional
# Safety Island's Cortex-R52 cluster is not enabled on commercial Jetson
# modules, and is not a place customers deploy code even on DRIVE.
#
# Where the BSP comes from, and why this script exists: NVIDIA does not publish
# `spe-freertos-bsp` as its own download. It is a 2.6 MB tarball *nested inside*
# the 216 MB Jetson Linux public sources archive, at
# `Linux_for_Tegra/source/spe-freertos-bsp.tbz2`. Nothing on the download page
# or in the SPE Developer Guide says so, which is an afternoon of searching for
# anyone who needs it. This script encodes the answer.
#
# Policy, mirroring scripts/bootstrap-asi.sh: never sudo, never write outside
# the repo's gitignored `build/` and the download cache. The vendor tree is
# staged, never edited in place, so a patch step can be added later without
# dirtying the download (the pattern scripts/provision-nxp-freertos.sh uses for
# the NXP kernel).
#
# Usage:
#   scripts/provision-orin-spe-bsp.sh                 # BSP + toolchain
#   scripts/provision-orin-spe-bsp.sh --no-toolchain  # BSP only
#   scripts/provision-orin-spe-bsp.sh --build         # also build stock demo
#   L4T_VERSION=36.4.3 scripts/provision-orin-spe-bsp.sh
#
# Environment:
#   L4T_VERSION        Jetson Linux version to fetch (default: 36.4.4).
#   ASI_VENDOR_CACHE   Download cache (default: ~/.cache/asi-vendor).
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CACHE="${ASI_VENDOR_CACHE:-${HOME}/.cache/asi-vendor}"
STAGE="${ROOT}/build/orin-spe"
L4T_VERSION="${L4T_VERSION:-36.4.4}"

# arm-gnu-toolchain 13.2.rel1 is what the SPE Developer Guide names for R36.4.
# NVIDIA does not redistribute it. Both host architectures are published, which
# matters here: the natural place to develop this is an Orin, which is aarch64.
TOOLCHAIN_VERSION="13.2.rel1"
TOOLCHAIN_BASE="https://developer.arm.com/-/media/Files/downloads/gnu/${TOOLCHAIN_VERSION}/binrel"

# Known-good digests. The public sources archive is pinned per L4T version; an
# unpinned version still installs, with a warning, because the BSP tarball
# carries NVIDIA's own sha1sum file and that is checked either way.
declare -A PUBLIC_SOURCES_SHA256=(
  [36.4.4]=cd4fa3bd2bbd73af7bec6cc4e1e2ec179a8933a217c830d346a0a0c48ea90661
)

DO_TOOLCHAIN=1
DO_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --no-toolchain) DO_TOOLCHAIN=0 ;;
    --build)        DO_BUILD=1 ;;
    -h|--help)      sed -n '5,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say()  { echo -e "\033[0;32m[spe-bsp]\033[0m $*"; }
warn() { echo -e "\033[0;33m[spe-bsp]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[spe-bsp]\033[0m $*" >&2; exit 1; }

for tool in curl tar sha256sum sha1sum make; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

# ---- 1. Jetson Linux public sources ----------------------------------------
# 36.4.4 -> r36_Release_v4.4. The release directory drops the patch component;
# the file name does not carry a version at all.
major="${L4T_VERSION%%.*}"                       # 36
rest="${L4T_VERSION#*.}"                         # 4.4
minor="${rest%%.*}"                              # 4
REL_DIR="r${major}_Release_v${minor}.${rest#*.}" # r36_Release_v4.4
PUBLIC_SOURCES_URL="https://developer.download.nvidia.com/embedded/L4T/${REL_DIR}/sources/public_sources.tbz2"
PUBLIC_SOURCES_TBZ="${CACHE}/public_sources_r${L4T_VERSION}.tbz2"

mkdir -p "${CACHE}"
if [ -f "${PUBLIC_SOURCES_TBZ}" ]; then
  say "public sources already cached: ${PUBLIC_SOURCES_TBZ}"
else
  say "downloading Jetson Linux ${L4T_VERSION} public sources (~216 MB)"
  say "  ${PUBLIC_SOURCES_URL}"
  curl -fL --progress-bar -o "${PUBLIC_SOURCES_TBZ}.part" "${PUBLIC_SOURCES_URL}" \
    || die "download failed — check L4T_VERSION=${L4T_VERSION} exists at ${REL_DIR}"
  mv "${PUBLIC_SOURCES_TBZ}.part" "${PUBLIC_SOURCES_TBZ}"
fi

expected="${PUBLIC_SOURCES_SHA256[${L4T_VERSION}]:-}"
actual="$(sha256sum "${PUBLIC_SOURCES_TBZ}" | cut -d' ' -f1)"
if [ -n "${expected}" ]; then
  [ "${expected}" = "${actual}" ] || die "sha256 mismatch for public sources
  expected ${expected}
  actual   ${actual}
Delete ${PUBLIC_SOURCES_TBZ} and re-run, or the download is not what we pinned."
  say "public sources sha256 OK"
else
  warn "no pinned sha256 for L4T ${L4T_VERSION} — got ${actual}"
  warn "add it to PUBLIC_SOURCES_SHA256 in this script once verified"
fi

# ---- 2. the nested SPE BSP tarball -----------------------------------------
# NVIDIA ships a sha1sum beside it, generated on their build machine. That is an
# integrity check against a truncated extract, not authenticity — the authentic
# link is the https download above.
say "extracting spe-freertos-bsp.tbz2 from the public sources archive"
rm -rf "${CACHE}/l4t-extract"
mkdir -p "${CACHE}/l4t-extract"
tar -xjf "${PUBLIC_SOURCES_TBZ}" -C "${CACHE}/l4t-extract" \
  Linux_for_Tegra/source/spe-freertos-bsp.tbz2 \
  Linux_for_Tegra/source/spe-freertos-bsp.tbz2.sha1sum \
  || die "no spe-freertos-bsp.tbz2 inside the archive — did NVIDIA move it?"

SPE_TBZ="${CACHE}/l4t-extract/Linux_for_Tegra/source/spe-freertos-bsp.tbz2"
want_sha1="$(cut -d' ' -f1 < "${SPE_TBZ}.sha1sum")"
have_sha1="$(sha1sum "${SPE_TBZ}" | cut -d' ' -f1)"
[ "${want_sha1}" = "${have_sha1}" ] || die "spe-freertos-bsp.tbz2 sha1 mismatch (${have_sha1} != ${want_sha1})"
say "SPE BSP sha1 OK (${have_sha1})"

# Staged fresh every run: the vendor tree must stay pristine so that a future
# patch step is visible as a patch rather than as drift.
rm -rf "${STAGE}/spe-freertos-bsp"
mkdir -p "${STAGE}"
tar -xjf "${SPE_TBZ}" -C "${STAGE}"
BSP="${STAGE}/spe-freertos-bsp"
[ -d "${BSP}/rt-aux-cpu-demo-fsp" ] && [ -d "${BSP}/fsp" ] && [ -d "${BSP}/FreeRTOSV10.4.3" ] \
  || die "staged tree is missing rt-aux-cpu-demo-fsp / fsp / FreeRTOSV10.4.3"
say "SPE BSP staged at ${BSP}"

# ---- 3. ARM bare-metal toolchain -------------------------------------------
CROSS_COMPILE=""
if [ "${DO_TOOLCHAIN}" = 1 ]; then
  host_arch="$(uname -m)"
  case "${host_arch}" in
    x86_64|aarch64) ;;
    *) die "no arm-gnu-toolchain build for host arch ${host_arch}" ;;
  esac
  TC_NAME="arm-gnu-toolchain-${TOOLCHAIN_VERSION}-${host_arch}-arm-none-eabi"
  TC_TAR="${CACHE}/${TC_NAME}.tar.xz"
  if [ -f "${TC_TAR}" ]; then
    say "toolchain already cached: ${TC_TAR}"
  else
    say "downloading ${TC_NAME} (~176 MB)"
    curl -fL --progress-bar -o "${TC_TAR}.part" "${TOOLCHAIN_BASE}/${TC_NAME}.tar.xz" \
      || die "toolchain download failed"
    mv "${TC_TAR}.part" "${TC_TAR}"
  fi
  # The extracted directory is NOT the archive's file name: ARM publishes
  # `…-13.2.rel1-….tar.xz` whose top-level directory is `…-13.2.Rel1-…`. So the
  # name is discovered by globbing what is on disk, never reconstructed. (Nor
  # read out of the archive with `tar -t | head`: head closes the pipe, tar dies
  # of SIGPIPE, and the script goes with it under `set -e`.)
  command -v xz >/dev/null || die "missing xz — install xz-utils"
  shopt -s nullglob
  tc_dirs=("${STAGE}"/arm-gnu-toolchain-*-"${host_arch}"-arm-none-eabi)
  if [ ${#tc_dirs[@]} -eq 0 ]; then
    say "extracting toolchain"
    tar -xJf "${TC_TAR}" -C "${STAGE}"
    tc_dirs=("${STAGE}"/arm-gnu-toolchain-*-"${host_arch}"-arm-none-eabi)
  fi
  shopt -u nullglob
  [ ${#tc_dirs[@]} -eq 1 ] || die "expected exactly one toolchain directory under ${STAGE}, found ${#tc_dirs[@]}"
  CROSS_COMPILE="${tc_dirs[0]}/bin/arm-none-eabi-"
  [ -x "${CROSS_COMPILE}gcc" ] || die "no arm-none-eabi-gcc under ${tc_dirs[0]}/bin"
  say "toolchain at ${CROSS_COMPILE}"
fi

# ---- 4. optional: build the stock demo, as a proof the staging is complete --
# This builds NVIDIA's own firmware, not ours. Its value is a known-good
# baseline: it proves toolchain + BSP + make wiring before any nano-ros code is
# in the picture, and its size is the budget everything else is measured
# against. Everything links into BTCM, which is 256 KB total on t234 — text,
# rodata, data, bss, heap and the five mode stacks share that one region.
if [ "${DO_BUILD}" = 1 ]; then
  [ -n "${CROSS_COMPILE}" ] || die "--build needs the toolchain (drop --no-toolchain)"
  say "building the stock t23x demo firmware"
  # FREERTOS_DIR / FSP_SRC_DIR / RT_AUX_DIR are passed EXPLICITLY, not left to
  # the Makefile's `?=` defaults. Those defaults only apply when the variable is
  # unset, and an ASI or nano-ros dev shell exports FREERTOS_DIR (pointing at
  # nano-ros's own kernel, with FREERTOS_PORT=GCC/ARM_CM3) — the vendor build
  # then silently compiles against a Cortex-M kernel tree and dies on a missing
  # `FreeRTOS.h`. A command-line assignment outranks the environment, which is
  # what makes this build reproducible inside an activated shell.
  make -C "${BSP}/rt-aux-cpu-demo-fsp" \
    SPE_FREERTOS_BSP="${BSP}" CROSS_COMPILE="${CROSS_COMPILE}" \
    RT_AUX_DIR="${BSP}/rt-aux-cpu-demo-fsp" \
    FSP_SRC_DIR="${BSP}/fsp/source" \
    FREERTOS_DIR="${BSP}/FreeRTOSV10.4.3/FreeRTOS/Source" \
    -j"$(nproc)" bin_t23x \
    || die "the stock demo failed to build — that is a staging problem, not a port problem"
  ELF="${BSP}/rt-aux-cpu-demo-fsp/out/t23x/spe.elf"
  BIN="${BSP}/rt-aux-cpu-demo-fsp/out/t23x/spe.bin"
  [ -f "${BIN}" ] || die "build reported success but ${BIN} is missing"
  say "built ${BIN}"
  "${CROSS_COMPILE}size" "${ELF}" || true
  used="$(stat -c%s "${BIN}")"
  say "$(printf 'binary %d bytes of the 262144-byte BTCM (%d%%)' "${used}" "$((used * 100 / 262144))")"
fi

# ---- 5. what the caller does next ------------------------------------------
cat <<EOF

$(say "done")

Export these for a build against the staged tree:

  export SPE_FREERTOS_BSP=${BSP}
$( [ -n "${CROSS_COMPILE}" ] && echo "  export CROSS_COMPILE=${CROSS_COMPILE}" )
  export FREERTOS_DIR=${BSP}/FreeRTOSV10.4.3/FreeRTOS/Source
  export FREERTOS_PORT=GCC/ARM_R5

Build NVIDIA's stock demo (baseline). Pass FREERTOS_DIR explicitly — the
Makefile takes it from the environment when set, and an activated ASI/nano-ros
shell exports one pointing at a different kernel:

  make -C ${BSP}/rt-aux-cpu-demo-fsp \\
    SPE_FREERTOS_BSP=${BSP} CROSS_COMPILE=\${CROSS_COMPILE} \\
    FREERTOS_DIR=${BSP}/FreeRTOSV10.4.3/FreeRTOS/Source bin_t23x

Flash it (on the host that flashes the Jetson, not necessarily this one):

  cp Linux_for_Tegra/bootloader/spe_t234.bin{,.orig}
  cp ${BSP}/rt-aux-cpu-demo-fsp/out/t23x/spe.bin Linux_for_Tegra/bootloader/spe_t234.bin
  sudo ./flash.sh -k A_spe-fw jetson-agx-orin-devkit internal

That last step needs root and a Jetson in recovery mode, so it is deliberately
not scripted here. See docs/roadmap/phase-10-orin-spe-entry.md for what comes
after the baseline.
EOF
