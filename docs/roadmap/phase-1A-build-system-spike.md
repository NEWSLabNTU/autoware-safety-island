# Phase 1A - import nano-ros as external dep + build spike

**Goal.** Wire nano-ros into ASI's Zephyr build as an **external dependency**
discovered via Zephyr module mechanism. Prove a minimal generated C++
publisher builds for the FVP target without disturbing the legacy raw-Cyclone
path.

**Status.** Draft, not started. **Revised 2026-05-18** — architecture pivot:
nano-ros is consumed, not vendored. Zephyr-module-driven integration; ASI's
own west/CMake stays in charge.

**Parallelism.** Blocks Groups B–D. Group E can prepare test fixtures while
this runs.

## Upstream contract

- nano-ros Zephyr module: `zephyr/` dir with `module.yml`
  (`name: nros`, `build: { cmake: zephyr, kconfig: zephyr/Kconfig }`).
- Kconfig API choice: `NROS_RUST_API` (default) | `NROS_C_API` | `NROS_CPP_API`.
- Kconfig RMW choice today: `NROS_RMW_ZENOH` (default) | `NROS_RMW_XRCE` |
  `NROS_RMW_DDS` (dust-dds). **Cyclone Kconfig added in Phase 1D.**
- Example template: `examples/zephyr/cpp/dds/talker/` — canonical copy-out
  scaffold. Self-contained `CMakeLists.txt` + `prj.conf` + `boards/` +
  `msg/` + `src/main.cpp`.
- nano-ros host orchestration: `just`. `just zephyr setup` initializes the
  in-tree `zephyr-workspace/`. Per-platform doctor/build/test recipes.

## Integration mechanism

Three viable options for importing nano-ros into ASI's Zephyr build:

| Option | How | Trade-off |
|---|---|---|
| (a) git submodule | `git submodule add nano-ros-autoware` under ASI | ASI controls revision pin; manual sync churn |
| (b) west project | Add to `actuation_module/west.yml` | west-native, fits Zephyr ecosystem; couples ASI's west to nano-ros's |
| (c) `ZEPHYR_EXTRA_MODULES` | Env handoff to existing sibling checkout | Loosest coupling; relies on env discipline |

**Preferred (b)**, with (c) documented as a developer-machine override.

Module discovery: nano-ros's `zephyr/` is the Zephyr module dir (contains
`module.yml`). Once Zephyr's module crawler finds it, `CONFIG_NROS` etc.
become available and `find_package(NanoRos)` resolves.

## Work Items

- [ ] **1A.1 - Decide on import mechanism.**
  Settle on (a) submodule, (b) west project, or (c) `ZEPHYR_EXTRA_MODULES`.
  Document fallbacks for dev container + CI. Capture the resulting
  reproducible checkout command in `docs/user_guide/quickstart.rst`.
- [ ] **1A.2 - Add nano-ros to ASI's west manifest (if option b).**
  Add `nano-ros-autoware` as a `projects:` entry in
  `actuation_module/west.yml`. Pin to a specific commit. Confirm `west
  update` produces the expected layout.
- [ ] **1A.3 - Verify Zephyr module discovery.**
  Build with the nano-ros checkout present; confirm Zephyr crawler finds
  its `zephyr/module.yml` and the `CONFIG_NROS` choice appears in
  `menuconfig`. No edits to existing `cyclonedds/` / `zephyr/` /
  `freertos-kernel/` vendor trees (those go away in Phases 1.3 / 1.4
  anyway — but A only adds, doesn't delete).
- [ ] **1A.4 - Add an opt-in build mode.**
  Extend `build.sh` with a flag like `--nano-ros-smoke` (or CMake option
  `-DASI_USE_NANO_ROS=ON`) so legacy Cyclone builds still work during
  migration. Smoke mode sets `CONFIG_NROS=y` + `CONFIG_NROS_CPP_API=y` +
  an available backend (Phase 1D switches to Cyclone).
- [ ] **1A.5 - Pick an interim backend for the smoke.**
  Cyclone-on-Zephyr Kconfig is owned by Phase 1D. For the spike, pick
  `CONFIG_NROS_RMW_DDS=y` (dust-dds, no router required) or
  `CONFIG_NROS_RMW_ZENOH=y` (needs host zenohd). Document the choice.
- [ ] **1A.6 - Build the `std_msgs/Int32` smoke.**
  Copy `examples/zephyr/cpp/dds/talker/` content into a temporary spike
  location (or into `actuation_module/test/`). Use `nros::init`,
  `nros::create_node`, `nros::Publisher<std_msgs::msg::Int32>`,
  `nros_generate_interfaces(std_msgs LANGUAGE CPP)`, and
  `NROS_APP_MAIN_REGISTER_ZEPHYR()`. Goal: linked ELF; optional FVP boot
  if backend permits.
- [ ] **1A.7 - Document bootstrap.**
  Record nano-ros checkout path (`NROS_ZEPHYR_WORKSPACE`, SDK `*_DIR`
  overrides) and host-side `just` invocations ASI's CI must run before
  building ASI.

## Acceptance Criteria

- [ ] `./build.sh --nano-ros-smoke` (or equivalent) produces a linked
      `build/actuation_module/zephyr/zephyr.elf` against an external
      nano-ros checkout.
- [ ] Legacy `./build.sh` still builds the current app path unchanged.
- [ ] `west update` (or chosen import mechanism) pulls nano-ros at a
      reproducible commit.
- [ ] Required build inputs are deterministic in dev container.
- [ ] No generated nano-ros files are committed in ASI.
- [ ] Missing nano-ros checkout fails with an actionable error
      (point at `just zephyr doctor`-style preflight).

## Likely Files

- `build.sh`
- `actuation_module/CMakeLists.txt`
- `actuation_module/prj_actuation.conf`
- `actuation_module/west.yml`
- `actuation_module/Kconfig`
- `docs/user_guide/quickstart.rst`
- `docs/user_guide/testing.rst`
- `~/repos/nano-ros-autoware/zephyr/module.yml` (reference only)
- `~/repos/nano-ros-autoware/examples/zephyr/cpp/dds/talker/*` (copy source)
