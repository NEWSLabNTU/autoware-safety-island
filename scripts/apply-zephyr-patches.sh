#!/usr/bin/env bash
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
#
# Apply this repo's Zephyr patches (patches/zephyr/*.patch) to the zephyr/
# checkout, idempotently: a patch that reverse-applies is already in, one
# that applies forward goes in, anything else is a conflict.
#
# `nros setup board` rewrites zephyr/, and a fresh checkout has none of these
# patches, so bootstrap-asi.sh and every build.sh Zephyr build run this.
# The CTF app_marker event and the priority-set mapping (once 0001, 0002)
# are nano-ros's patch set now. See patches/zephyr/README.md.
#
# Usage: scripts/apply-zephyr-patches.sh [zephyr-dir]
# Exit 1 if a patch neither is applied nor applies.

set -euo pipefail

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
zephyr="${1:-${root}/zephyr}"
rc=0
for patch in "${root}"/patches/zephyr/*.patch; do
  [ -e "${patch}" ] || continue
  name="$(basename "${patch}")"
  if git -C "${zephyr}" apply --check --reverse "${patch}" >/dev/null 2>&1; then
    :
  elif git -C "${zephyr}" apply "${patch}" >/dev/null 2>&1; then
    echo "applied zephyr patch: ${name}"
  else
    echo "zephyr patch ${name} neither is applied nor applies to ${zephyr};" \
      "it may need a refresh against the current pin." >&2
    rc=1
  fi
done
exit "${rc}"
