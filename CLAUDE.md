# CLAUDE.md

Guidance for Claude Code working in this repo. See `AGENTS.md` for the
human-facing contributor guide; this file repeats key bits and adds
Claude-specific notes.

## Project

Autoware Safety Island: standalone app running Autoware's trajectory follower
(MPC lateral + PID longitudinal) on an Arm safety-class processor. Exchanges
control commands with Autoware over DDS (and optionally CAN). On this branch
the middleware is nano-ros (modules/nros, pinned in lockstep with the
nano-ros project in actuation_module/west.yml). Targets:

- Zephyr: FVP `fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp` (default) and the
  NXP S32Z270 RTU0 R52 (`s32z270dc2_rtu0_r52@D`, link only).
- FreeRTOS: POSIX simulator (Linux host), QEMU mps3-an536 (emulated
  Cortex-R52), NXP S32Z2 (link only).

No changes to Autoware itself are required; this repo bundles the relevant
Autoware components under `actuation_module/src/autoware/`.

## Layout

```
actuation_module/            nano-ros workspace root (`nros configure .`)
  CMakeLists.txt             Hand-written Zephyr app of the test programs only
                             (every controller image: `nros build <image>`)
  west.yml                   West manifest (zephyr v3.7.0, nano-ros pin)
  nros-codegen.toml          Message field bounds for codegen
  nros-sdk.lock              SDK tool versions (`nros setup`)
  boards/                    Test-program overlays + confs
  src/
    controller_pkg/          The controller component (rclcpp API) + the vendored
                             autoware_trajectory_follower_node (the node class)
    visionpilot_msgs/, safety_island_msgs/  Supervision message packages
    controller_bringup/      system.toml (images, sched tasks, knob rows) + launch
                             file + contract; zephyr/ = the Zephyr images'
                             os_config fragments (prj-*.conf, overlays)
    s32z270_zephyr_board/    Workspace board package (S32Z270 on Zephyr)
    s32z2_board_glue/        NXP S32Z2 FreeRTOS board glue
    autoware/                autoware_controller_libs: vendored Autoware controllers
                             (MPC, PID) and utility libraries
    asi_common/              Platform layer: include/{common,platform}, message
                             umbrella, support sources, pthread shim, Eigen patch;
                             a Zephyr module for the application's Kconfig
                             symbols (zephyr/module.yml, zephyr/Kconfig)
  test/                      Test programs; test/host = dependency-free host tests
build.sh                     Top-level build driver
scripts/                     Provisioning, demo runners, trace tools
demo/                        Docker Compose demo (Autoware 2.0.0 + bridge)
documentation/
  design/                    Design notes
  roadmap/                   Phase records (phase-14 = current conventions work)
  user_guide/                Sphinx user docs
modules/nros/                nano-ros (submodule; move with west.yml)
zephyr/                      Zephyr v3.7.0 - do NOT edit
```

## Build & test commands

- `scripts/bootstrap-asi.sh` provisions a host; the devcontainer does the
  same (`./launch-dev-container.sh`).
- `./build.sh --platform zephyr-fvp|zephyr-s32z|freertos-posix|freertos-an536|freertos-s32z2 -d <dir>`
  runs `nros build <image>` (images in controller_bringup/system.toml; on
  the FVP `--network tap`, `--trace-stats`, `--trace`, `--trace-ring` pick
  the `fvp-tap*` / `*-stats` / `*-trace*` image). Sizing is knob rows in
  system.toml, never exported variables (an exported one wins over a row).
- `./build.sh --unit-test | --dds-publisher | --dds-subscriber` build one
  Zephyr test program; clean (`-c`) between test-mode switches.
- CI lanes run locally as `.github/scripts/run-freertos-posix-ci.sh`,
  `run-freertos-an536-ci.sh` and `run-zephyr-fvp-ci.sh` from the repo root.
  Unset `CYCLONEDDS_URI`, `ROS_DOMAIN_ID` and `RMW_IMPLEMENTATION` first: an
  inherited Cyclone config changes the POSIX smoke's interface line.
- Host tests: `cmake -S actuation_module/test/host -B build/host-tests`.
- Docs: `python3 -m pip install -r documentation/requirements.txt`, then
  `sphinx-build -b html documentation documentation/_build/html`.
- On the fork, CI runs on non-main branches only by
  `gh workflow run "Build and Test" --ref <branch>`.

## Coding conventions

- C++17, embedded-friendly. Allocations, blocking calls, platform assumptions
  stay explicit.
- 2-space indentation in CMake and nearby C/C++.
- `snake_case` for files, functions, locals. `PascalCase` only where matching
  existing Autoware or message types.
- Platform-specific code behind `platform_*` interfaces; gate with
  `PLATFORM_ZEPHYR` / FreeRTOS-specific paths.
- Keep SPDX copyright headers in new source + docs files.

## nano-ros branch context

- `nano-ros` holds the attempts; `nano-ros-migration` is the clean series
  (same tree at each sync point). Upstream is
  autowarefoundation/autoware-safety-island `main`.
- Moving the nano-ros pin: update modules/nros and the nano-ros `revision`
  in actuation_module/west.yml together (the FVP lane asserts the lockstep).
- Current work: documentation/roadmap/phase-14-nano-ros-conventions.md.
- Keep MPC / PID / CAN application logic in C++. Keep CAN tests
  middleware-independent.

## Commits & PRs

- Conventional Commits: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`. Imperative,
  scoped subjects (e.g. `feat: add CAN output path for control commands`).
- PR body: describe behavior changes, list build/test commands run, link
  issues, attach logs/screenshots for demo / AVH / visualizer work.

## Security & secrets

Do not commit: `.env`, AVH tokens, generated VPN configs, logs, local build
outputs. Start AVH config from `template.env`. Keep machine-specific files
untracked.

## Things to avoid

- Editing `zephyr/` unless explicitly
  updating that dependency.
- Modifying upstream Autoware components under `src/autoware/` beyond what
  the port requires - prefer adapter shims in `common/`.
- Skipping the `./build.sh -c` clean step when switching test modes
  (`--unit-test` <-> `--dds-publisher` etc.) - stale CMake cache will bite.
