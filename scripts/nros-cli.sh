# shellcheck shell=bash
# Which nano-ros CLI the island builds with. Sourced by build.sh and the CI
# lane scripts; `nros_cli_select` sets and exports:
#
#   NROS_CLI        the nros binary every later step runs
#   NROS_CLI_MODE   "release" or "source"
#
# sets the array NROS_SETUP_INDEX_ARGS (the `nros setup` index flags for that
# CLI), and puts the CLI and its launch resolver first on PATH.
#
# release (the default): the prebuilt CLI of the nano-ros release that
#   actuation_module/nros-toolchain.toml pins (`version = "..."`), the way the
#   nano-ros book pins one (guide/build/install-options.md, "Pinning a
#   version"). A missing release is installed with that release's own
#   install.sh (`--version <v>`) into $NROS_HOME (default ~/.nros). The
#   release's own binary runs, not the launcher, so no dispatch is involved.
#   modules/nros (the Zephyr module and the CMake road read it) must be the
#   release's tagged commit; actuation_module/west.yml says the same
#   (LOCKSTEP).
# source (opt-in, NROS_DEV_CLI=1): build the CLI and the launch resolver from
#   modules/nros, for trying nano-ros changes no release has yet (branch
#   nano-ros-next is built this way). Only this path skips the CLI's
#   staleness gate, and only on a clean checkout.

nros_cli_select() {
  local root="${ROOT_DIR:?ROOT_DIR unset}"
  local nros_repo="${root}/modules/nros"
  local pin="${root}/actuation_module/nros-toolchain.toml"

  if [ "${NROS_DEV_CLI:-0}" != "1" ]; then
    NROS_CLI_MODE=release
    local version
    version="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${pin}" 2>/dev/null | head -1)"
    if [ -z "${version}" ]; then
      echo "nros-cli: ${pin} pins no release (version = \"...\")." >&2
      return 1
    fi
    local home="${NROS_HOME:-${HOME}/.nros}"
    NROS_CLI="${home}/sdk/nros/${version}/bin/nros"
    if [ ! -x "${NROS_CLI}" ]; then
      echo "nros-cli: installing nano-ros ${version} into ${home}"
      local installer="${nros_repo}/scripts/install.sh"
      if [ -f "${installer}" ]; then
        NROS_HOME="${home}" sh "${installer}" --version "${version}"
      else
        curl -fsSL "https://raw.githubusercontent.com/NEWSLabNTU/nano-ros/nros-${version}/scripts/install.sh" \
          | NROS_HOME="${home}" sh -s -- --version "${version}"
      fi
    fi
    if [ ! -x "${NROS_CLI}" ]; then
      echo "nros-cli: nano-ros ${version} is not at ${NROS_CLI} after its install." >&2
      return 1
    fi
    # modules/nros must be the release's commit: a CLI of another version
    # would disagree with the sources the Zephyr module and CMake road read.
    local tag_commit head_commit
    tag_commit="$(git -C "${nros_repo}" rev-parse -q --verify "refs/tags/nros-${version}^{commit}" 2>/dev/null || true)"
    head_commit="$(git -C "${nros_repo}" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "${tag_commit}" ] && [ "${tag_commit}" != "${head_commit}" ]; then
      echo "nros-cli: modules/nros is ${head_commit:-missing}, not release nros-${version} (${tag_commit})." >&2
      echo "  Move the submodule and actuation_module/west.yml to the tag (LOCKSTEP), or build from source with NROS_DEV_CLI=1." >&2
      return 1
    fi
    NROS_SETUP_INDEX_ARGS=()
  else
    NROS_CLI_MODE=source
    if [ ! -f "${nros_repo}/packages/cli/Cargo.toml" ]; then
      echo "nros-cli: nano-ros checkout missing at modules/nros (git submodule update --init modules/nros)." >&2
      return 1
    fi
    # Always run cargo: a fresh CLI is a no-op, and any partial check misses
    # part of the CLI's real input closure.
    cargo build --release --manifest-path "${nros_repo}/packages/cli/Cargo.toml" -p nros-cli
    cargo build --release \
      --manifest-path "${nros_repo}/packages/cli/nros-launch-resolve/Cargo.toml"
    mkdir -p "${nros_repo}/packages/cli/target/release"
    ln -sf "${nros_repo}/packages/cli/nros-launch-resolve/target/release/nros-launch-resolve" \
           "${nros_repo}/packages/cli/target/release/nros-launch-resolve"
    NROS_CLI="${nros_repo}/packages/cli/target/release/nros"
    # The CLI's staleness gate guards a nano-ros developer against a CLI older
    # than sources they just edited. Our own build writes into the stamped tree
    # after the CLI is built (`nros configure`), so on a CLEAN checkout it would
    # misfire; skip it only then. Nested submodule pointers do not count.
    if [ -z "$(git -C "${nros_repo}" status --porcelain --ignore-submodules=all 2>/dev/null)" ]; then
      export NROS_SKIP_STALE_CHECK=1
    else
      echo "nros-cli: modules/nros has local changes; the CLI staleness gate stays on."
    fi
    NROS_SETUP_INDEX_ARGS=(--index "${nros_repo}/nros-sdk-index.toml")
  fi
  export NROS_CLI NROS_CLI_MODE
  export PATH="$(dirname "${NROS_CLI}"):${PATH}"
  echo "nros-cli: ${NROS_CLI_MODE} CLI ${NROS_CLI}"
}
