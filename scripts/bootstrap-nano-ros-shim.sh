#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Build the in-tree nano-ros `nros` CLI — the codegen + orchestration tool
# `nros_generate_interfaces()` / `nano_ros_node_register()` shell out to.
#
# POST-218: the codegen tool is the `nros` CLI shipped from the in-tree
# sub-workspace at `modules/nros/packages/cli/` (Phase 218 monorepo merge).
# This REPLACES the pre-218 path that built a separate `nros-codegen` binary
# from the now-retired `packages/codegen` submodule (Phase 195.D / 218) and
# staged serdes/templates — the `nros` CLI bundles the base interfaces +
# templates itself.
#
# Output: `modules/nros/packages/cli/target/release/nros`.
# build.sh passes it to CMake as `-D_NANO_ROS_CODEGEN_TOOL=<path>` (the
# documented override; the Zephyr module's nros_generate_interfaces.cmake +
# NanoRosEntry.cmake resolve `nros` from that var, then $NROS_CLI, then PATH).
#
# Idempotent — re-run freely. Invoked by scripts/bootstrap-asi.sh and build.sh.

set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SRC="${ROOT}/modules/nros"
CLI_MANIFEST="${SRC}/packages/cli/Cargo.toml"
CLI_BIN="${SRC}/packages/cli/target/release/nros"

if [[ ! -d "${SRC}" ]]; then
    echo "[bootstrap-nros] modules/nros/ missing — run \`west update\` first." >&2
    exit 1
fi
if [[ ! -f "${CLI_MANIFEST}" ]]; then
    echo "[bootstrap-nros] ${CLI_MANIFEST} missing — the nano-ros pin predates the" >&2
    echo "                 Phase 218 in-tree CLI (packages/cli/). Bump the west.yml" >&2
    echo "                 nano-ros revision to a post-218 commit." >&2
    exit 1
fi

# safe.directory for the west-managed checkouts (host or container).
git config --global --add safe.directory '*' || true

# ---- rustup / cargo ----
if ! command -v cargo >/dev/null; then
    echo "[bootstrap-nros] Installing rustup (stable toolchain, minimal profile)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal >/dev/null
fi
export PATH="${HOME}/.cargo/bin:${PATH}"
command -v cargo >/dev/null || {
    echo "[bootstrap-nros] cargo not on PATH after rustup install" >&2; exit 1; }

# ---- init the CLI's nested git submodules ----
# The CLI sub-workspace path-depends on two nano-ros submodules
# (packages/cli/third-party/{ros-launch-manifest,play_launch_parser}). west
# fetches the nano-ros repo but NOT its nested submodules, so cargo fails with
# "failed to read .../third-party/ros-launch-manifest/types/Cargo.toml" unless
# they are initialised here.
echo "[bootstrap-nros] Initialising the CLI's third-party submodules..."
git -C "${SRC}" submodule update --init --recursive \
    packages/cli/third-party/ros-launch-manifest \
    packages/cli/third-party/play_launch_parser

# ---- build the nros CLI (equivalent to `just setup-cli`) ----
# The CLI sub-workspace has its own Cargo.toml/Cargo.lock (host-only deps kept
# outside the runtime no_std view — Phase 214.F.3); build it standalone.
echo "[bootstrap-nros] Building the nros CLI (release)..."
cargo build --release --manifest-path "${CLI_MANIFEST}" --bin nros

if [[ ! -x "${CLI_BIN}" ]]; then
    echo "[bootstrap-nros] expected ${CLI_BIN} after build — not found." >&2
    exit 1
fi

# ---- nros-c cbindgen header (source-tree include the Zephyr build needs) ----
# nros-c's build.rs emits include/nros/nros_generated.h (cbindgen). Trigger
# once so the Zephyr include path has it. `cargo check` suffices.
if [[ ! -f "${SRC}/packages/core/nros-c/include/nros/nros_generated.h" ]]; then
    echo "[bootstrap-nros] Generating nros-c cbindgen header..."
    ( cd "${SRC}" && cargo check --release -p nros-c --no-default-features \
        --features 'rmw-cffi,platform-zephyr,ros-humble,std' >/dev/null )
fi

echo "[bootstrap-nros] Ready:"
echo "  nros CLI: ${CLI_BIN}"
echo "  (pass via -D_NANO_ROS_CODEGEN_TOOL=${CLI_BIN}, or put on PATH / \$NROS_CLI)"
