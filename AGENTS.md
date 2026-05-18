# Repository Guidelines

## Project Structure & Module Organization

This repository builds Autoware Safety Island, a Zephyr/FreeRTOS actuation
application that exchanges Autoware control data over ROS middleware. Main
application code lives in `actuation_module/`: public headers under `include/`,
platform ports under `include/platform/{zephyr,freertos}/`, Zephyr entry/build
files at the module root, Autoware-derived components under `src/autoware/`,
and test programs under `test/`. Documentation sources are in `docs/`;
active migration plans live in `docs/roadmap/` and design notes in
`docs/design/`. `demo/` contains Docker Compose, launch, bridge,
visualizer, and sample map assets. `cyclonedds/`, `zephyr/`, and
`freertos-kernel/` are large upstream dependency trees; avoid drive-by edits
there unless updating that dependency.

## Build, Test, and Development Commands

- `./launch-dev-container.sh`: start the project dev container with host
  networking, ccache, and this repo mounted at `/autoware-safety-island`.
- `./build.sh`: build CycloneDDS host tools, then build the default Zephyr FVP
  target `fvp_baser_aemv8r_smp`.
- `./build.sh -t s32z270dc2_rtu0_r52@D`: build for the S32Z board target.
- `./build.sh -c`: remove `build/` and `install/`.
- `python3 -m pip install -r docs/requirements.txt`: install docs
  dependencies before local Sphinx builds.
- `sphinx-build -b html documentation docs/_build/html`: build local
  documentation after editing `.rst` sources.

## Coding Style & Naming Conventions

Use C++17-compatible, embedded-friendly code: keep allocations, blocking calls,
and platform assumptions explicit. Follow existing 2-space indentation in
CMake and nearby C/C++ files. Use `snake_case` for files, functions, and local
variables; use `PascalCase` only where matching existing Autoware or message
types. Keep platform-specific code behind `platform_*` interfaces and
`PLATFORM_ZEPHYR`/FreeRTOS-specific paths. Preserve SPDX copyright headers in
new source and documentation files.

## nano-ros Migration Notes

Work on the `nano-ros` branch, tracking `newslab/nano-ros`. Use
`~/repos/nano-ros-autoware` for clean nano-ros patches; treat
`~/repos/nano-ros` as reference only because it may contain unrelated local
changes. Follow `docs/roadmap/phase-1*.md` for migration tasks. Keep
MPC/PID/CAN application logic in C++ and prefer adapter layers around
`common/node` or `common/dds` over broad algorithm rewrites.

## Testing Guidelines

Standalone Zephyr test programs live in `actuation_module/test/`. Build one at
a time: `./build.sh --unit-test`, `./build.sh --dds-publisher`, or
`./build.sh --dds-subscriber`; the resulting ELF is
`build/actuation_module/zephyr/zephyr.elf`. Clean between test-mode switches
with `./build.sh -c`. Add focused tests near the subsystem changed, for example
DDS/node checks in `unit_test.cpp` or CAN checks in `can_output_test.cpp`.
For nano-ros work, keep CAN tests middleware-independent and add backend smoke
tests before replacing the legacy Cyclone path.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit prefixes such as `feat:`, `fix:`,
`docs:`, `ci:`, and `chore:`. Keep subjects imperative and scoped, for example
`feat: add CAN output path for control commands`. Pull requests should describe
behavior changes, list build/test commands run, link issues when available, and
include logs or screenshots for demo, AVH, or visualizer changes.

## Security & Configuration Tips

Do not commit secrets from `.env`, AVH tokens, generated VPN configs, logs, or
local build outputs. Start from `template.env` for AVH configuration and keep
machine-specific files untracked.
