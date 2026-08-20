#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# bootstrap-asi.sh — provision a LOCAL host (no devcontainer) to build the
# Autoware Safety Island actuation module against nano-ros (workspace mode).
#
# Mirrors the devcontainer Dockerfile (.devcontainer/Dockerfile) as a host
# script. Policy (per nano-ros CLAUDE.md "never sudo"): the no-root steps run
# automatically (rustup, pip --user, the Zephyr SDK into your home, `west
# update`, the nros CLI build); for system packages that need root it DETECTS
# what is missing and PRINTS the exact `sudo apt install …` line for you to run
# — it never invokes sudo itself.
#
# After a successful run:  source ./activate-asi.sh  &&  ./build.sh
#
# What it does NOT do: install ARM FVP (license-gated, x86-only) — that is for
# the *runtime* FVP smoke only and stays opt-in (see the FVP note at the end).
#
# Usage: scripts/bootstrap-asi.sh [--no-sdk] [--no-update]
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ZSDK_VERSION="0.16.3"   # pinned to the devcontainer Dockerfile
SDK_DIR="${ZEPHYR_SDK_INSTALL_DIR:-${HOME}/zephyr-sdk-${ZSDK_VERSION}}"
DO_SDK=1; DO_UPDATE=1
for a in "$@"; do case "$a" in --no-sdk) DO_SDK=0;; --no-update) DO_UPDATE=0;; esac; done

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

# ---- 5. Zephyr SDK 0.16.3 (aarch64-zephyr-elf), into \$HOME — no root ----
if ((DO_SDK)) && [[ ! -d "${SDK_DIR}" ]]; then
  say "installing Zephyr SDK ${ZSDK_VERSION} → ${SDK_DIR} …"
  case "$(uname -m)" in x86_64) A=x86_64;; aarch64|arm64) A=aarch64;; *) die "unsupported host arch $(uname -m) for the Zephyr SDK";; esac
  TARBALL="zephyr-sdk-${ZSDK_VERSION}_linux-${A}.tar.xz"
  URL="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZSDK_VERSION}/${TARBALL}"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
  wget -q --show-progress -O "${tmp}/${TARBALL}" "${URL}"
  # extract only the arm toolchains + setup (mirror the Dockerfile's slimming).
  tar -xJf "${tmp}/${TARBALL}" -C "${HOME}" \
      "zephyr-sdk-${ZSDK_VERSION}/arm-zephyr-eabi/" \
      "zephyr-sdk-${ZSDK_VERSION}/aarch64-zephyr-elf/" \
      "zephyr-sdk-${ZSDK_VERSION}/setup.sh" \
      "zephyr-sdk-${ZSDK_VERSION}/cmake" \
      "zephyr-sdk-${ZSDK_VERSION}/sdk_toolchains" \
      "zephyr-sdk-${ZSDK_VERSION}/sdk_version"
  "${SDK_DIR}/setup.sh" -c -t arm-zephyr-eabi
  "${SDK_DIR}/setup.sh" -c -t aarch64-zephyr-elf
fi
[[ -d "${SDK_DIR}" ]] && say "Zephyr SDK: ${SDK_DIR}" || warn "Zephyr SDK skipped (--no-sdk); set ZEPHYR_SDK_INSTALL_DIR yourself."

# ---- 6. build the nano-ros `nros` CLI (the codegen tool) ----
# Inlined (the old bootstrap-nano-ros-shim.sh is retired) — mirrors build.sh.
say "building the nano-ros nros CLI…"
cargo build --release \
  --manifest-path "${ROOT}/modules/nros/packages/cli/Cargo.toml" -p nros-cli

# ---- 6b. board-driven Zephyr provisioning (nano-ros Phase 215.J) ----
# The board crate provisions THIS consumer's zephyr tree: fetches the board's
# RMW source (cyclonedds), applies nano-ros's zephyr patch set to ${ZEPHYR_BASE},
# rustup-adds the board's Rust target(s), and brings RUST_SUPPORTED via the
# board's Kconfig overlay module. Replaces the hand stopgaps (manual zephyr
# patches / RUST_SUPPORTED / cyclonedds fetch). One board-driven command.
NROS_CLI="${ROOT}/modules/nros/packages/cli/target/release/nros"
if [[ ! -x "${NROS_CLI}" ]]; then die "nros CLI not built (expected ${NROS_CLI})."; fi
# FRICTION (eace28852 pin): `nros setup board` still resolves the pre-phase-337
# board-crate path `packages/boards/nros-board-<name>` and misses bundle boards
# under `packages/boards/nros-board-zephyr/boards/<name>/` (nros-cli-core
# setup.rs run_board vs the bundle-aware resolver `nros board info` uses).
# Until that lands upstream, run the four setup-board steps by hand — same
# order as run_board: (a) RMW source, (b) zephyr-line patches, (c) rust
# targets, (d) zephyr-lang-rust module presence (west update already fetched
# it at the board's pinned rev).
say "provisioning zephyr for board fvp-aemv8r-smp (manual setup-board steps)…"
( cd "${ROOT}/modules/nros" \
  && "${NROS_CLI}" setup --source cyclonedds-src \
  && bash scripts/zephyr/patches/3.7.sh "${ROOT}" )
rustup target add aarch64-unknown-none
[[ -d "${ROOT}/modules/lang/rust" ]] || \
  die "zephyr-lang-rust module missing at modules/lang/rust — run west update."

# ---- 7. write activate-asi.sh (source it before ./build.sh) ----
cat > "${ROOT}/activate-asi.sh" <<EOF
# Generated by scripts/bootstrap-asi.sh — source before ./build.sh
export ZEPHYR_BASE="${ZEPHYR_BASE}"
export ZEPHYR_SDK_INSTALL_DIR="${SDK_DIR}"
export PATH="\${HOME}/.cargo/bin:\${HOME}/.local/bin:${ROOT}/modules/nros/packages/cli/target/release:\${PATH}"
export NROS_CLI="${ROOT}/modules/nros/packages/cli/target/release/nros"
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
