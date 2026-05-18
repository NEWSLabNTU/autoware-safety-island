#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap the nano-ros shim build chain inside the dev container.
# Idempotent — run as often as you like.
#
# Steps:
#   1. Verify nano-ros checkout (west-fetched at modules/nros/).
#   2. Ensure rustup + cargo on PATH (install if missing).
#   3. Init nano-ros codegen submodule (packages/codegen → colcon-nano-ros).
#   4. Drop nros-cli{,-core} from the codegen Cargo workspace (they
#      reference a sibling `play_launch` tree not in our pin).
#   5. cargo build --release -p nros-codegen-c → modules/nros/build/install/bin/nros-codegen.
#   6. Stage nros-serdes crate + cmake templates under the install prefix.
#
# After this script runs, `./build.sh --nano-ros-shim` finds everything
# nros_generate_interfaces() needs without manual intervention.

set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SRC="${ROOT}/modules/nros"
PREFIX="${SRC}/build/install"

if [[ ! -d "${SRC}" ]]; then
    echo "[bootstrap] modules/nros/ missing — run \`west update\` first." >&2
    exit 1
fi

# ---- safe.directory for all the west-managed checkouts ----
git config --global --add safe.directory '*' || true

# ---- rustup ----
if ! command -v cargo >/dev/null; then
    echo "[bootstrap] Installing rustup (stable toolchain, minimal profile)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal >/dev/null
fi
export PATH="${HOME}/.cargo/bin:${PATH}"
command -v cargo >/dev/null || {
    echo "[bootstrap] cargo not on PATH after rustup install" >&2; exit 1; }

# ---- codegen submodule ----
if [[ ! -f "${SRC}/packages/codegen/packages/Cargo.toml" ]]; then
    echo "[bootstrap] Initialising packages/codegen submodule..."
    git -C "${SRC}" submodule update --init packages/codegen
fi

# ---- workspace cleanup ----
# nros-cli + nros-cli-core reference a `play_launch` sibling tree that
# isn't part of our checkout. Drop them from the codegen workspace so
# `cargo build -p nros-codegen-c` resolves cleanly. Idempotent.
WORKSPACE_TOML="${SRC}/packages/codegen/packages/Cargo.toml"
if grep -q '"nros-cli-core"' "${WORKSPACE_TOML}" 2>/dev/null; then
    sed -i '/"nros-cli-core",/d; /"nros-cli",/d' "${WORKSPACE_TOML}"
    echo "[bootstrap] Dropped nros-cli{,-core} from codegen workspace members."
fi

# ---- nros-codegen build ----
mkdir -p "${PREFIX}/bin"
if [[ ! -x "${PREFIX}/bin/nros-codegen" ]] \
   || [[ "${SRC}/packages/codegen/packages/nros-codegen-c/src/main.rs" \
         -nt "${PREFIX}/bin/nros-codegen" ]]; then
    echo "[bootstrap] Building nros-codegen-c..."
    (
        cd "${SRC}/packages/codegen/packages"
        cargo build --release -p nros-codegen-c
        cp target/release/nros-codegen "${PREFIX}/bin/"
    )
fi

# ---- nros-serdes standalone staging ----
SERDES_DIR="${PREFIX}/share/nano-ros/rust/nros-serdes"
mkdir -p "${SERDES_DIR%/*}"
if [[ ! -d "${SERDES_DIR}" ]] \
   || [[ "${SRC}/packages/core/nros-serdes/src/lib.rs" \
         -nt "${SERDES_DIR}/Cargo.toml" ]]; then
    echo "[bootstrap] Staging nros-serdes crate..."
    rm -rf "${SERDES_DIR}"
    cp -r "${SRC}/packages/core/nros-serdes" "${SERDES_DIR}"
    # Standalone Cargo.toml (no workspace inheritance — Cargo.workspace
    # dependencies don't resolve outside the parent workspace).
    cat > "${SERDES_DIR}/Cargo.toml" <<'EOF'
[package]
name = "nros-serdes"
version = "0.1.0"
edition = "2024"
license = "MIT OR Apache-2.0"
[features]
default = ["std"]
std = []
alloc = []
[dependencies]
heapless = "0.8"
[lib]
path = "src/lib.rs"
EOF
fi

# ---- cmake templates ----
TEMPLATE_DIR="${PREFIX}/lib/cmake/NanoRos"
mkdir -p "${TEMPLATE_DIR}"
cp "${SRC}/packages/codegen/packages/nros-codegen-c/cmake/cpp_ffi_Cargo.toml.in" \
   "${TEMPLATE_DIR}/"
cp "${SRC}/packages/codegen/packages/nros-codegen-c/cmake/ffi_lib_rs.in" \
   "${TEMPLATE_DIR}/"

# ---- nros-c source-tree header regen ----
# nros-c's build.rs writes `packages/core/nros-c/include/nros/nros_generated.h`
# (cbindgen output). Trigger once so the file exists for the Zephyr build's
# include path. `cargo check` is enough — no need to compile full target.
if [[ ! -f "${SRC}/packages/core/nros-c/include/nros/nros_generated.h" ]]; then
    echo "[bootstrap] Generating nros-c cbindgen header..."
    (
        cd "${SRC}"
        cargo check --release -p nros-c --no-default-features \
            --features 'rmw-cffi,platform-zephyr,ros-humble,std' >/dev/null
    )
fi

echo "[bootstrap] Ready:"
echo "  nros-codegen: ${PREFIX}/bin/nros-codegen"
echo "  serdes:       ${SERDES_DIR}"
echo "  templates:    ${TEMPLATE_DIR}"
