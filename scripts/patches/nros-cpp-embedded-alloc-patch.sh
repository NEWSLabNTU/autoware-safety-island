#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# FRICTION patch (nano-ros pin eace28852, unfixed at upstream HEAD 12f5d1d8f):
# the Zephyr EMBEDDED C++ cyclonedds lane composes nros-cpp cargo features as
#   rmw-cffi,platform-zephyr,ros-humble        (zephyr/CMakeLists.txt:387)
# without `alloc`, while nros-cpp's error mapper hard-references the
# alloc-gated `TransportError::BackendDynamic` variant (lib.rs:793, un-gated
# by phase-361 W3 / issue 0591 on the claim that no buildable configuration
# lacks the variant). native_sim appends `,std` (implies alloc) so upstream
# fixtures never see it; an embedded aarch64-none consumer does:
#   error[E0599]: no variant ... named `BackendDynamic` found for enum
#   `nros_node::TransportError`
# Appending `,alloc` is the phase-361 W8.d spelling: the END USER declares
# whether the image may allocate, and ASI's image has a real heap (picolibc
# malloc arena). Idempotent; self-retires when upstream fixes the lane.
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
F="${ROOT}/modules/nros/zephyr/CMakeLists.txt"
OLD='set(_nros_cpp_features "rmw-cffi,platform-zephyr,ros-humble")'
NEW='set(_nros_cpp_features "rmw-cffi,platform-zephyr,ros-humble,alloc")'

if grep -qF "${NEW}" "${F}"; then
  echo "[nros-cpp-embedded-alloc-patch] already applied"
elif grep -qF "${OLD}" "${F}"; then
  sed -i "s|${OLD}|${NEW}|" "${F}"
  echo "[nros-cpp-embedded-alloc-patch] patched ${F}"
else
  echo "[nros-cpp-embedded-alloc-patch] pattern not found — upstream likely fixed the lane; retire this patch" >&2
  exit 1
fi
