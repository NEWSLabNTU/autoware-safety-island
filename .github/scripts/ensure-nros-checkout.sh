#!/usr/bin/env bash
# Put modules/nros at the commit this repo's gitlink names, before `west
# update` reads actuation_module/west.yml.
#
# The manifest's `self: import:` reads nano-ros's s32z270-rtu0-zephyr board
# fragment (zephyr-lang-rust, hal_nxp, cmsis) from the modules/nros checkout,
# so west cannot load the manifest without it, and a stale checkout (a
# restored CI cache from an older pin) would hand it an older fragment.
#
# The checkout keeps the shape `west update` gives it: a plain clone with its
# own .git directory and a `newslab` remote (run-zephyr-fvp-ci.sh's lockstep
# check fetches that remote's heads). Not `git submodule update`: its .git
# file points into .git/modules/, which the CI cache of modules/ leaves
# behind.
#
# Usage: .github/scripts/ensure-nros-checkout.sh   (from the repo root)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URL="https://github.com/NEWSLabNTU/nano-ros.git"
DIR="${ROOT_DIR}/modules/nros"
rev="$(git -C "${ROOT_DIR}" rev-parse HEAD:modules/nros)"

# A checkout of its own (west's clone, or a local `git submodule update`)
# stays; anything else (the empty directory actions/checkout leaves, or a
# .git file whose target the cache did not keep) is replaced.
top="$(git -C "${DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
if [ "${top}" != "${DIR}" ]; then
  rm -rf "${DIR}"
  git init -q "${DIR}"
fi
git -C "${DIR}" remote get-url newslab >/dev/null 2>&1 \
  || git -C "${DIR}" remote add newslab "${URL}"
if ! git -C "${DIR}" cat-file -e "${rev}^{commit}" 2>/dev/null; then
  git -C "${DIR}" fetch -q newslab "${rev}"
fi
git -C "${DIR}" checkout -q -f --detach "${rev}"
echo "ensure-nros-checkout: modules/nros at ${rev}"
