#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# bootstrap-asi.sh — provision a LOCAL host (no devcontainer) to build the
# Autoware Safety Island actuation module against nano-ros (workspace mode).
#
# Mirrors the devcontainer Dockerfile (.devcontainer/Dockerfile) as a host
# script. Policy (per nano-ros CLAUDE.md "never sudo"): the no-root steps run
# automatically (rustup, pip --user, `west update`, the nros CLI build); for
# system packages that need root it DETECTS what is missing and PRINTS the
# exact `sudo apt install …` line for you to run — it never invokes sudo
# itself.
#
# What nano-ros provisions is nano-ros's: `nros setup --workspace` reads every
# image's board and RMW from the bringups' system.toml and fetches their
# toolchains and sources into ~/.nros (the Zephyr SDK, arm-none-eabi-gcc,
# QEMU, the FreeRTOS kernel, lwIP, Cyclone DDS), `nros setup board` prepares
# the west workspace for the FVP board, and `nros doctor` checks the result.
# This script keeps only the steps nano-ros does not cover: the system
# packages west and Zephyr need, foreign-owned paths, rustup, the west
# workspace (this repo is its manifest), this repo's own Zephyr patches, and
# activate-asi.sh.
#
# After a successful run:  source ./activate-asi.sh  &&  ./build.sh
#
# What it does NOT do: install ARM FVP (license-gated, x86-only) — that is for
# the *runtime* FVP smoke only and stays opt-in (see the FVP note at the end).
#
# Usage: scripts/bootstrap-asi.sh [--no-update]
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
DO_UPDATE=1
for a in "$@"; do case "$a" in --no-update) DO_UPDATE=0;; esac; done

say()  { echo -e "\033[0;32m[asi-bootstrap]\033[0m $*"; }
warn() { echo -e "\033[0;33m[asi-bootstrap]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[asi-bootstrap]\033[0m $*" >&2; exit 1; }

# ---- 1. system packages (DETECT + INSTRUCT, never sudo) ----
# The build needs these on PATH; only an OS package manager (root) provides them.
declare -A PKG=(
  [cmake]=cmake [ninja]=ninja-build [dtc]=device-tree-compiler
  [wget]=wget [xz]=xz-utils [python3]=python3 [pip3]=python3-pip
)
missing_apt=()
for cmd in "${!PKG[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || missing_apt+=("${PKG[$cmd]}")
done
if ((${#missing_apt[@]})); then
  warn "Missing system packages (need your OS package manager / root):"
  warn "  Debian/Ubuntu:  sudo apt-get install -y ${missing_apt[*]}"
  warn "  (install those, then re-run this script). NOT installing them for you."
  die  "system packages missing — see the apt line above."
fi
say "system packages present."

# ---- 1b. foreign-owned paths (DETECT + INSTRUCT, never sudo) ----
# A devcontainer run from a pre-fixuid image (Dockerfile without `USER
# dev:dev`, launcher without `--user $(id -u):$(id -g)` — i.e. anything before
# commit 86a1787) executed as root, so every file it created in the bind mount
# came out root-owned. The wreckage outlives the fix: `west update` then dies
# with a bare `cannot lock ref ... Permission denied` deep inside a project,
# which reads like a git bug rather than an ownership problem. Detect it here
# and print the exact chown instead.
#
# Only the SUBTREE ROOTS are reported — one chown -R per root covers
# everything beneath, and listing 28k individual paths helps nobody.
say "checking for foreign-owned paths (pre-fixuid devcontainer leftovers)…"
mapfile -t foreign_roots < <(
  python3 - "${ROOT}" <<'PY'
import os, sys
root = sys.argv[1]
me = os.getuid()
skip = {".git"}


def owner(path):
    try:
        return os.lstat(path).st_uid
    except OSError:
        return None


out = []
for dirpath, dirnames, filenames in os.walk(root, topdown=True):
    dirnames[:] = [d for d in dirnames if d not in skip]
    if owner(dirpath) != me:
        out.append(dirpath)
        dirnames[:] = []          # whole subtree is foreign; one chown covers it
        continue
    for name in filenames:
        path = os.path.join(dirpath, name)
        if owner(path) != me:
            out.append(path)
print("\n".join(out))
PY
)
# Drop the empty line python emits when there is nothing to report.
foreign_roots=("${foreign_roots[@]/#/}")
if ((${#foreign_roots[@]})) && [[ -n "${foreign_roots[0]}" ]]; then
  warn "Paths in this checkout are not owned by $(id -un) ($(id -u)):"
  for p in "${foreign_roots[@]}"; do
    warn "    $(stat -c '%U:%G' "$p") ${p}"
  done
  warn ""
  warn "These are almost certainly left by a devcontainer run that predates"
  warn "the fixuid adoption (86a1787). git and west cannot write into them."
  warn "Hand them back with:"
  warn "  sudo chown -R $(id -un):$(id -gn) ${foreign_roots[*]}"
  warn ""
  warn "Any __pycache__ among them may simply be deleted instead."
  die  "foreign-owned paths present — see the chown line above."
fi
say "ownership clean."

# ---- 2. Rust (rustup, user install — no root) ----
if ! command -v cargo >/dev/null 2>&1; then
  say "installing rustup (stable, minimal)…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal >/dev/null
fi
export PATH="${HOME}/.cargo/bin:${PATH}"
command -v cargo >/dev/null || die "cargo not on PATH after rustup install."
say "rust: $(cargo --version)"

# ---- 3. west + pyelftools (pip --user — no root) ----
if ! command -v west >/dev/null 2>&1; then
  say "installing west + pyelftools (pip --user)…"
  python3 -m pip install --user -U west pyelftools >/dev/null
fi
export PATH="${HOME}/.local/bin:${PATH}"
command -v west >/dev/null || die "west not on PATH after pip --user install (add ~/.local/bin to PATH)."
say "west: $(west --version)"

# ---- 4. west workspace init + update (fetch nano-ros + zephyr + HALs) ----
# ASI is the manifest repo (actuation_module/west.yml). `west init -l` makes
# this checkout the workspace; `west update` fetches the manifest projects
# (cmsis, hal_nxp, nano-ros @ the pin, zephyr@3.7). The private NXP
# `s32ct_config` is an S32Z2-only git submodule, NOT a west project — the FVP
# target does not need it, so it is never fetched here.
# modules/nros is a tracked git submodule (lockstep with the west.yml pin);
# init it (plus zephyr and the CLI's play_launch dep) before west adopts them.
say "git submodule init (zephyr, modules/nros)…"
git -C "${ROOT}" submodule update --init zephyr modules/nros
git -C "${ROOT}/modules/nros" submodule update --init packages/cli/third-party/play_launch
if [[ ! -d "${ROOT}/.west" ]]; then
  say "west init -l (manifest = actuation_module/)…"
  west init -l "${ROOT}/actuation_module"
fi
if ((DO_UPDATE)); then
  say "west update (cmsis, hal_nxp, nano-ros, zephyr — may take a while)…"
  west update
fi
ZEPHYR_BASE="$(west list -f '{abspath}' zephyr 2>/dev/null || true)"
[[ -d "${ZEPHYR_BASE}" ]] || die "zephyr not found after west update (ZEPHYR_BASE='${ZEPHYR_BASE}')."
say "ZEPHYR_BASE = ${ZEPHYR_BASE}"
# Zephyr's own python deps.
python3 -m pip install --user -r "${ZEPHYR_BASE}/scripts/requirements.txt" >/dev/null 2>&1 || \
  warn "could not install ${ZEPHYR_BASE}/scripts/requirements.txt — install manually if the build complains."

# ---- 6. the nano-ros `nros` CLI (the codegen tool) ----
# The release actuation_module/nros-toolchain.toml pins (installed into
# $NROS_HOME if missing), or modules/nros's with NROS_DEV_CLI=1; the same
# selection build.sh and CI make (scripts/nros-cli.sh).
say "selecting the nano-ros nros CLI…"
# shellcheck source=nros-cli.sh
ROOT_DIR="${ROOT}" source "${ROOT}/scripts/nros-cli.sh"
ROOT_DIR="${ROOT}" nros_cli_select || die "no nros CLI (see above)."

# ---- 6b. board-driven Zephyr provisioning (nano-ros Phase 215.J) ----
# The board crate provisions THIS consumer's zephyr tree: fetches the board's
# RMW source (cyclonedds), applies nano-ros's zephyr patch set to ${ZEPHYR_BASE},
# rustup-adds the board's Rust target(s), and brings RUST_SUPPORTED via the
# board's Kconfig overlay module. Replaces the hand stopgaps (manual zephyr
# patches / RUST_SUPPORTED / cyclonedds fetch). One board-driven command.
# Board-driven provisioning (nano-ros issue 0729 fixed upstream: bundle
# boards resolve through setup board again). Fetches the board's RMW
# source, applies the zephyr-line patch set to ${ROOT}/zephyr, rustup-adds
# the board's targets, checks the zephyr-lang-rust pin.
say "provisioning zephyr for board fvp-aemv8r-smp (nros setup board)…"
( cd "${ROOT}/actuation_module" && "${NROS_CLI}" setup board fvp-aemv8r-smp \
    --zephyr-workspace "${ROOT}" )
# ---- 6c. every image's toolchains and sources (nros setup --workspace) ----
# One plan over every bringup's [image.*] boards and RMWs: the Zephyr SDK
# (the Zephyr boards), arm-none-eabi-gcc and QEMU (mps3-an536-freertos), the
# FreeRTOS kernel and lwIP (the FreeRTOS boards) and Cyclone DDS. A system
# package a tool needs is printed as the command to run, never installed. The
# NXP-licensed S32Z2 packages are only checked; the Arm FVP is user-provided
# (see the note at the end).
say "provisioning every image's board and RMW (nros setup --workspace)…"
( cd "${ROOT}/actuation_module" && "${NROS_CLI}" setup "${NROS_SETUP_INDEX_ARGS[@]}" --workspace . )
# The freertos-s32z2 lane's Cortex-R52 cross profile (a link-only lane, whose
# Rust target no board plan above adds).
rustup target add armv8r-none-eabihf
[[ -d "${ROOT}/modules/lang/rust" ]] || \
  die "zephyr-lang-rust module missing at modules/lang/rust — run west update."

# ---- 6d. health check (nros doctor) ----
# The controller's images, the toolchain pin against west.yml's nano-ros
# revision, the SDK paths. A problem here is reported, not fatal: doctor also
# names the license-gated packages a link-only lane cannot fetch.
say "nros doctor (controller_bringup)…"
( cd "${ROOT}/actuation_module" && "${NROS_CLI}" doctor --config src/controller_bringup ) ||
  warn "nros doctor reported problems (above)."

ZSDK_DIR="$(cd "${ROOT}/actuation_module" && "${NROS_CLI}" sdk-path zephyr-sdk 2>/dev/null || true)"
[[ -d "${ZSDK_DIR}" ]] || die "no Zephyr SDK in the nros store after nros setup (nros sdk-path zephyr-sdk)."
say "Zephyr SDK: ${ZSDK_DIR}"

# ---- 7. write activate-asi.sh (source it before ./build.sh) ----
cat > "${ROOT}/activate-asi.sh" <<EOF
# Generated by scripts/bootstrap-asi.sh — source before ./build.sh
export ZEPHYR_BASE="${ZEPHYR_BASE}"
export ZEPHYR_SDK_INSTALL_DIR="${ZSDK_DIR}"
export PATH="\${HOME}/.cargo/bin:\${HOME}/.local/bin:$(dirname "${NROS_CLI}"):\${PATH}"
export NROS_CLI="${NROS_CLI}"
EOF
# Local FVP model (phase-3 W3 tools/ layout) — exported only when extracted.
if [[ -x "${ROOT}/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin/FVP_BaseR_AEMv8R" ]]; then
  echo "export ARMFVP_BIN_PATH=\"${ROOT}/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin\"" >> "${ROOT}/activate-asi.sh"
fi
say "wrote ${ROOT}/activate-asi.sh"

cat <<EOF

[asi-bootstrap] DONE. To build:
    source ./activate-asi.sh
    ./build.sh                 # FVP (fvp_baser_aemv8r_smp) build

Runtime FVP smoke (242.5.2) additionally needs ARM Fixed Virtual Platforms
(FVP_BaseR_AEMv8R) — license-gated, x86 Linux only, NOT installed by this
script. Get it from developer.arm.com, put it on PATH (or set ARMFVP_BIN_PATH),
then run the FVP target. The compile above does not need FVP.
EOF
