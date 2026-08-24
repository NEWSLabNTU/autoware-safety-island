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
# Board-driven provisioning (nano-ros issue 0729 fixed upstream: bundle
# boards resolve through setup board again). Fetches the board's RMW
# source, applies the zephyr-line patch set to ${ROOT}/zephyr, rustup-adds
# the board's targets, checks the zephyr-lang-rust pin.
say "provisioning zephyr for board fvp-aemv8r-smp (nros setup board)…"
( cd "${ROOT}/modules/nros" && "${NROS_CLI}" setup board fvp-aemv8r-smp \
    --zephyr-workspace "${ROOT}" )
# ---- 6b.1 local zephyr patches (on top of the nano-ros set) ----
# `nros setup board` rewrites ${ROOT}/zephyr, so anything this repo needs
# beyond nano-ros's patch set has to be re-applied here or it vanishes on the
# next provisioning run. Each is checked with --reverse first so re-running
# bootstrap is idempotent. See patches/zephyr/README.md.
if compgen -G "${ROOT}/patches/zephyr/*.patch" >/dev/null; then
  for patch in "${ROOT}"/patches/zephyr/*.patch; do
    if git -C "${ROOT}/zephyr" apply --check --reverse "${patch}" >/dev/null 2>&1; then
      say "zephyr patch already applied: $(basename "${patch}")"
    elif git -C "${ROOT}/zephyr" apply "${patch}" >/dev/null 2>&1; then
      say "applied zephyr patch: $(basename "${patch}")"
    else
      warn "could not apply $(basename "${patch}") — it may need a refresh against the current pin."
    fi
  done
fi

# Host idlc: the pin's cyclonedds cmake resolves idlc from the nros SDK store
# (~/.nros/sdk/cyclonedds/<ver>/bin/idlc) before PATH. Provision the board's
# tool ∪ rmw set (cyclonedds prebuilt + cyclonedds-src + rosidl; the gated
# arm-fvp entry only prints its license hint).
say "provisioning SDK store (cyclonedds idlc + rosidl)…"
( cd "${ROOT}/modules/nros" \
  && "${NROS_CLI}" setup fvp-aemv8r-smp --rmw cyclonedds )

# ---- 6c. FreeRTOS POSIX lane (phase-4 W5.a) ----
# Kernel source (nros-provisioned SSOT) + the launch-resolver helper that
# `nros sync` requires beside the nros binary (nano-ros issue-0285 rule:
# resolved by absolute sibling path, never $PATH).
say "provisioning FreeRTOS kernel + nros-launch-resolve…"
( cd "${ROOT}/modules/nros" && "${NROS_CLI}" setup --source freertos-kernel )
( cd "${ROOT}/modules/nros" \
  && cargo build --release \
       --manifest-path packages/cli/nros-launch-resolve/Cargo.toml )
ln -sf "${ROOT}/modules/nros/packages/cli/nros-launch-resolve/target/release/nros-launch-resolve" \
       "${ROOT}/modules/nros/packages/cli/target/release/nros-launch-resolve"
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
