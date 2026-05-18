# CLAUDE.md

Guidance for Claude Code working in this repo. See `AGENTS.md` for the
human-facing contributor guide; this file repeats key bits and adds
Claude-specific notes.

## Project

Autoware Safety Island: standalone app running Autoware's trajectory follower
(MPC lateral + PID longitudinal) on an Arm safety-class processor. Exchanges
control commands with Autoware over DDS (and optionally CAN). Targets:

- **Zephyr RTOS** — production target (FVP `fvp_baser_aemv8r_smp` default,
  NXP `s32z270dc2_rtu0_r52@D` for hardware).
- **FreeRTOS POSIX simulator** — development/testing on Linux host.

No changes to Autoware itself are required; this repo bundles the relevant
Autoware components under `actuation_module/src/autoware/`.

## Layout

```
actuation_module/         App code
  include/
    common/{can,clock,dds,logger,node}/   Platform-agnostic interfaces
    platform/{zephyr,freertos}/           Platform-specific ports + headers
  src/
    main.cpp                              App entry (Zephyr-style)
    common/dds/                           DDS network config impl
    autoware/                             Vendored Autoware components
  freertos/freertos_main.cpp              FreeRTOS POSIX entry
  test/                                   Standalone test programs
  boards/                                 Zephyr board overlays + confs
  west.yml                                Zephyr west manifest
  prj_actuation.conf, Kconfig             Zephyr build config
build.sh                                  Top-level build driver
launch-dev-container.sh                   Dev container entry
demo/                                     Docker Compose, launch, bridge, viz
docs/
  design/                                 Design notes (architecture, CAN, nano-ros)
  roadmap/                                Migration plans (phase-1*.md)
  user_guide/                             Sphinx user docs
cyclonedds/, zephyr/, freertos-kernel/    Upstream dependency trees — do NOT
                                          edit unless updating that dependency
```

## Build & test commands

- `./launch-dev-container.sh` — start dev container (host networking, ccache,
  repo mounted at `/autoware-safety-island`).
- `./build.sh` — build CycloneDDS host tools, then default Zephyr FVP target.
- `./build.sh -t s32z270dc2_rtu0_r52@D` — build for S32Z board.
- `./build.sh -c` — clean `build/` and `install/`.
- `./build.sh --unit-test | --dds-publisher | --dds-subscriber` — build one
  test program at a time. Output ELF: `build/actuation_module/zephyr/zephyr.elf`.
  Clean between test-mode switches.
- Docs: `python3 -m pip install -r docs/requirements.txt`, then
  `sphinx-build -b html documentation docs/_build/html`.

FreeRTOS POSIX simulator entry is `actuation_module/freertos/freertos_main.cpp`;
it renames the Zephyr-style `main` to `actuation_main` via `-Dmain=actuation_main`
and launches it as a FreeRTOS task. CI smoke-test design lives in
`docs/design/`.

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

- Work happens on `nano-ros` (tracks `newslab/nano-ros`). Main branch is `main`.
- Clean nano-ros patches: `~/repos/nano-ros-autoware`. Treat `~/repos/nano-ros`
  as reference only (may contain unrelated local changes).
- Migration plan: `docs/roadmap/phase-1*.md`.
- Keep MPC / PID / CAN application logic in C++. Prefer adapter layers around
  `common/node` or `common/dds` over broad algorithm rewrites.
- Keep CAN tests middleware-independent. Add backend smoke tests before
  replacing the legacy CycloneDDS path.

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

- Editing `cyclonedds/`, `zephyr/`, or `freertos-kernel/` unless explicitly
  updating that dependency.
- Modifying upstream Autoware components under `src/autoware/` beyond what
  the port requires — prefer adapter shims in `common/`.
- Skipping the `./build.sh -c` clean step when switching test modes
  (`--unit-test` ↔ `--dds-publisher` etc.) — stale CMake cache will bite.
