# nano-ros Pin Bump (7dfe4fe4e → eace28852) + Submodule Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bump ASI's nano-ros from `7dfe4fe4e` to `eace28852ab0ef8273d2b2cc1919f695586d57e0` (~2394 commits), carry nano-ros as a git submodule at `modules/nros`, realign ASI with nano-ros's current documented consumer workflow, and get the `zephyr-fvp` build + CI test modes green again.

**Architecture:** ASI stays the manifest authority (west.yml, `import: false`); the nano-ros checkout becomes a git submodule whose pointer and the west.yml `revision:` are kept in lockstep. Build keeps the board-crate consumer shape (`nano_ros_use_board(fvp-aemv8r-smp)` before `find_package(Zephyr)`), updated to whatever CMake verbs exist at the new pin. Fix walls ASI-side with adapter shims; log nano-ros frictions in the phase-3 roadmap doc (do NOT touch `~/repos/nano-ros` — owned by another agent).

**Tech Stack:** Zephyr v3.7.0 + zephyr-lang-rust `404fcefd` (both unchanged at new pin), west, cargo (in-tree `nros` CLI at `packages/cli`), CMake, FVP `fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp`.

**Spec:** This plan embeds its spec (survey findings below). Companion context: `docs/roadmap/phase-3-modern-nano-ros-migration.md` (prior bump's eight-wall history), nano-ros book chapter `book/src/porting/board-crate-import.md` inside the submodule (the ASI-archetype consumer recipe, includes "Migrating an existing hand-glued consumer").

## Global Constraints

- nano-ros pin: `eace28852ab0ef8273d2b2cc1919f695586d57e0` (NEWSLabNTU/nano-ros main, 2026-08-20). Everywhere it appears it must match: `.gitmodules`-tracked submodule pointer AND `actuation_module/west.yml:42`.
- Zephyr stays `v3.7.0`; zephyr-lang-rust stays `404fcefdbab0f2711cd342a1fab9d2eda52a1ba9` (nano-ros's 3.7-line west.yml still pins these — verified at new pin).
- NEVER run any command against `~/repos/nano-ros` (another agent owns it). Reference clone for history digging: `/tmp/claude-1000005/-home-aeon-repos-autoware-safety-island/99f302e8-47a5-493f-830e-0e7db99cd859/scratchpad/nano-ros` (read-only) — or use the new submodule checkout.
- No edits under `cyclonedds/`, `zephyr/`, `freertos-kernel/` (ASI rule). FreeRTOS build paths are nano-ros-free — must stay untouched and green.
- Conventional Commits. C++17. 2-space indent. SPDX headers on new files.
- `main` has NOT moved (`a76b63f` = merge-base = origin/main = upstream/main). No rebase step exists in this plan.

## Spec: survey findings that drive the tasks

**Consumer-facing breaking changes since `7dfe4fe4e`** (from nano-ros git survey):

1. **Repo re-layout (phase-321):** `packages/core/{nros,nros-c,nros-cpp}` → `packages/api/`; `packages/dds/nros-rmw-cyclonedds` → `packages/rmw/cyclonedds/nros-rmw-cyclonedds`. Any ASI reference to old internal paths breaks.
2. **CLI:** in-tree at `packages/cli` (unchanged path, package name `nros-cli`, binary `packages/cli/target/release/nros`), BUT its play_launch third-party deps consolidated into one submodule `packages/cli/third-party/play_launch` — must `git submodule update --init` inside nano-ros before `cargo build`. New subcommands: `model-path`, `profile`, `sdk-path`, `init`. `nros setup board <board> --zephyr-workspace <dir>` still exists and is the sanctioned consumer provisioning step.
3. **`nros sync` / `nros-patch.toml`:** generated file with absolute paths, gitignored; a stale one breaks cargo with "failed to load source for dependency nros". Regenerate after checkout moves/re-pins.
4. **Entry baking:** `nano_ros_entry(NAME … BRINGUP <dir> LAUNCH default|<file> | MODEL <yaml> [TYPED] [PANIC platform|halt|own])` is the current verb set; `LAUNCH` (resolved at configure time via `nros model-path`) is the canonical spelling, `MODEL` still accepted; `HOST` removed. **Default panic behavior changed**: embedded images now call `k_panic()` instead of halting — pass `PANIC halt` to keep old behavior.
5. **Component registration:** current verbs are `nano_ros_auto_add_library` + `nros_components_register_node(<lib> PLUGIN ns::Class EXECUTABLE name SHAPE rclcpp [TYPED])`. ASI's `nano_ros_add_node(... CLASS ... TYPED SHAPE rclcpp HEADER ... SOURCES ...)` / `nano_ros_add_executable(... BOARD zephyr MODEL ... TYPED)` (RFC-0048 era) may or may not still exist — Task 3 verifies before migrating.
6. **C++ API:** `Executor::spin(duration_ms, poll_ms)` GONE — `spin(poll_ms=10)` now blocks until shutdown; bounded form is `spin_for(duration_ms, poll_ms)`. One-arg `spin(100)` still compiles and blocks forever (silent trap). `nros_platform_clock_ms/us` removed — use `nros_platform_clock_ns()`. `nros/component_node.hpp` path + namespace unchanged. New: `create_polling_subscription`.
7. **Kconfig (additive, no renames, but knobs went live):** `CONFIG_NROS_EXECUTOR_MAX_CBS` default 16→4 and now actually forwarded (previously inert); pool knobs resolve environment-over-Kconfig (build.sh's `NROS_MAX_PARAMETERS=256`, `NROS_EXECUTOR_MAX_CBS=16`, `NROS_SUBSCRIPTION_BUFFER_SIZE=16384` env exports therefore still win — keep them). `CONFIG_NROS_CYCLONE_CONFIG_XML` now wired (replaces baked profile if set — ASI doesn't set it).
8. **Codegen:** per-package C++ FFI crates (`<pkg>__nano_ros_cpp`); stale pre-split `_ffi.rs` in old build dirs must be cleaned (fresh `build/` avoids this). `nros_generate_interfaces` still exists (ament analogue `nano_ros_generate_interfaces` in workspace mode). Codegen tool resolution unchanged: `-D_NANO_ROS_CODEGEN_TOOL` → `$NROS_CLI` → PATH.
9. **Board crates → conf bundles (phase-337):** board KEY `fvp-aemv8r-smp` unchanged; tree moved to `packages/boards/nros-board-zephyr/boards/fvp-aemv8r-smp/`. S32Z board crate was DELETED upstream (no in-tree bundle) — zephyr-s32z stays known-broken (pre-existing gap G7), out of scope.
10. **CycloneDDS fork pointer:** now NEWSLabNTU/cyclonedds branch `nano-ros` @ `8601ca66a` (was `1d794c0a`), fetched by `nros setup board` as `cyclonedds-src`. Includes ddsrt mutex, environ backend, tier core-pin fixes.
11. **HEAD caveat:** #260 SMP work is in flight at exactly `eace28852` (a53 board bring-up — different board than ASI's armv8r FVP). If the FVP smoke regresses inexplicably, try pinning a few commits earlier and record the wall.

**ASI touchpoints** (from ASI survey — the checklist Task 3+ works through):

- `build.sh:299-415` — CLI bootstrap (paths verified unchanged), env knobs, `-D_NANO_ROS_CODEGEN_TOOL`, board id mapping, overlay conf, ARMFVP flags.
- `actuation_module/CMakeLists.txt:14-21` (`nano_ros_use_board(fvp-aemv8r-smp)` before `find_package(Zephyr)`), `:78` `find_package(nano_ros …)`, `:86-89` entry bake (`nano_ros_add_executable … MODEL src/controller_bringup/config/system_model.yaml TYPED`), `:44` `--allow-multiple-definition`.
- `actuation_module/src/controller_pkg/CMakeLists.txt:82-147` — `nano_ros_add_node`, expected target name `controller_pkg_controller_component`, generated-header dir `${CMAKE_BINARY_DIR}/src/autoware/autoware_msgs/nano_ros_cpp`.
- `actuation_module/src/autoware/autoware_msgs/CMakeLists.txt:19-53` — `nros_generate_interfaces` x10 packages, `${pkg}_GENERATED_RS_FILES` parent-scope export.
- C++: `include/common/node/node_nros.hpp` (polling shim: `nros::create_node`, `Publisher::publish`, `Subscription::try_recv`, `Result::{ok,raw}`), `node.hpp:27` (`AsiNode = nros::ComponentNode`), `controller.cpp:23` (`NROS_COMPONENT(Controller)`), `controller_node.cpp` (declare_parameter, member-fn-pointer `create_timer`/`create_subscription`, `QoS::default_profile().keep_last(1)` — the #42 fix, must survive), `board_network_hook.cpp:22` (weak `nros_board_network_wait`), `clock.hpp:16` + `messages.hpp` (generated-header names).
- Pre-existing bugs to fix en route: `scripts/bootstrap-asi.sh:114` calls deleted `scripts/bootstrap-nano-ros-shim.sh`; `nano_ros_overlay.conf:20` stale `CONFIG_NROS_CODEGEN_TOOL` devcontainer path.
- CI: `.github/workflows/build-ci.yml` west-cache keyed on `hashFiles('actuation_module/west.yml')` (bump invalidates — good); `.github/scripts/run-zephyr-fvp-ci.sh` 5 phases grep boot markers ("Starting Controller Node", "Controller Node Started", "Actuation Safety Island is Live", "=== All Tests Passed ===", "DDS loopback test passed").

---

### Task 1: Submodule + pin bump + workspace bring-up

**Files:**
- Modify: `.gitmodules` (add nano-ros entry)
- Modify: `actuation_module/west.yml:42` (revision bump)
- Create: `modules/nros` (submodule at `eace28852`)

**Interfaces:**
- Produces: an initialized west workspace at repo root (`.west/`, `zephyr/`, `modules/lang/rust/`, `actuation_module/zephyr_modules/hal/*`) and a nano-ros checkout at `modules/nros` with its play_launch submodule initialized. Later tasks build against it.

- [ ] **Step 1: Add nano-ros as a git submodule**

```bash
cd /home/aeon/repos/autoware-safety-island
git submodule add -b main https://github.com/NEWSLabNTU/nano-ros.git modules/nros
git -C modules/nros checkout eace28852ab0ef8273d2b2cc1919f695586d57e0
git -C modules/nros submodule update --init packages/cli/third-party/play_launch
```

(Full `--recursive` init not needed: RMW transport submodules are fetched by `nros setup board`; only the CLI's play_launch dep is required to build `nros`.)

- [ ] **Step 2: Bump west.yml in lockstep**

In `actuation_module/west.yml` change line 42:

```yaml
      revision: eace28852ab0ef8273d2b2cc1919f695586d57e0
```

Add one comment line above the existing nano-ros comment block:

```yaml
    # LOCKSTEP: this revision must equal the modules/nros git submodule pointer.
```

- [ ] **Step 3: Initialize the west workspace**

```bash
cd /home/aeon/repos/autoware-safety-island
git submodule update --init zephyr
pip3 install --user west pyelftools 2>/dev/null || true
west init -l actuation_module
west update
```

Expected: zephyr adopted at `v3.7.0`, `modules/lang/rust` at `404fcefd`, hal modules fetched. If `west update` fights the pre-existing `modules/nros` checkout (west adopting an existing repo at the same SHA is normally a no-op fetch+checkout), record exactly what it did; if it detaches or re-fetches harmlessly, fine. Known prior wall: west failing to fetch a bare SHA — if `eace28852` is unreachable for west, `git -C modules/nros fetch origin main` first.

- [ ] **Step 4: Build the nros CLI**

```bash
cargo build --release --manifest-path modules/nros/packages/cli/Cargo.toml -p nros-cli
modules/nros/packages/cli/target/release/nros version
```

Expected: builds; version prints. If cargo fails with "failed to load source for dependency nros": run `modules/nros/packages/cli/target/release/nros sync` — chicken-and-egg unlikely since nros-patch.toml is gitignored (fresh checkout has none); if sync is required before build, use a bootstrap cargo invocation per `modules/nros/scripts/bootstrap.sh` (read it, follow it).

- [ ] **Step 5: Provision the board (sanctioned consumer step)**

```bash
cd /home/aeon/repos/autoware-safety-island/modules/nros
./packages/cli/target/release/nros setup board fvp-aemv8r-smp --zephyr-workspace /home/aeon/repos/autoware-safety-island
```

Expected: fetches cyclonedds-src (fork `8601ca66a`), applies zephyr 3.7-line patches to `./zephyr`, `rustup target add aarch64-unknown-none`, verifies zephyr-lang-rust pin. NOTE: this patches the `zephyr/` submodule working tree — that dirt is expected and must NOT be committed (`zephyr` pointer stays `36940db`... whatever `west update` left; verify `git submodule status zephyr` unchanged before commit).

- [ ] **Step 6: Commit (submodule + pin only — workspace stays untracked)**

```bash
cd /home/aeon/repos/autoware-safety-island
git status   # verify: only .gitmodules, modules/nros, actuation_module/west.yml staged-able; zephyr pointer UNCHANGED
git add .gitmodules modules/nros actuation_module/west.yml
git commit -m "chore(phase-3): adopt nano-ros as git submodule + bump pin to eace28852

west.yml revision and the modules/nros submodule pointer are lockstep;
the submodule is the checkout authority, west adopts it in place."
```

### Task 2: Fix bootstrap-asi.sh (pre-existing breakage + new workflow)

**Files:**
- Modify: `scripts/bootstrap-asi.sh` (line 114 region and lines 76–83)

**Interfaces:**
- Consumes: Task 1's submodule layout.
- Produces: a host bootstrap that a fresh user can run end-to-end (this is the "ASI as nano-ros user example" deliverable).

- [ ] **Step 1: Reproduce the breakage**

```bash
bash -n scripts/bootstrap-asi.sh && grep -n "bootstrap-nano-ros-shim" scripts/bootstrap-asi.sh
```

Expected: grep hits line ~114 — the script calls `scripts/bootstrap-nano-ros-shim.sh`, which no longer exists.

- [ ] **Step 2: Fix**

Replace the shim call with the inlined CLI build (mirror build.sh lines 318–328), and add submodule init before west steps. Around lines 76–83, ensure order is:

```bash
git -C "${ROOT}" submodule update --init zephyr modules/nros
git -C "${ROOT}/modules/nros" submodule update --init packages/cli/third-party/play_launch
west init -l actuation_module 2>/dev/null || true
west update
```

Replace line 114 (`bash "${ROOT}/scripts/bootstrap-nano-ros-shim.sh"`) with:

```bash
cargo build --release \
  --manifest-path "${ROOT}/modules/nros/packages/cli/Cargo.toml" -p nros-cli
```

Keep the existing `nros setup board fvp-aemv8r-smp --zephyr-workspace "${ROOT}"` call (lines 122–131) and the `activate-asi.sh` generation (134–144) as-is.

- [ ] **Step 3: Verify**

```bash
bash -n scripts/bootstrap-asi.sh
grep -n "bootstrap-nano-ros-shim" scripts/bootstrap-asi.sh   # expect: no hits
```

Full re-run of bootstrap on this already-provisioned host is optional; if run, it must be idempotent and exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/bootstrap-asi.sh
git commit -m "fix(bootstrap): drop call to retired bootstrap-nano-ros-shim.sh; init submodules"
```

### Task 3: Verify CMake verb surface at the new pin, migrate if renamed

**Files:**
- Possibly modify: `actuation_module/CMakeLists.txt:86-89`, `actuation_module/src/controller_pkg/CMakeLists.txt:82-147`, `actuation_module/src/autoware/autoware_msgs/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 workspace.
- Produces: CMake that configures against the new pin. Component target name (whatever the new verb emits) is consumed by controller_pkg's include-dir surgery at `controller_pkg/CMakeLists.txt:91-147` — keep that block pointed at the right target.

- [ ] **Step 1: Establish which verbs exist at the pin (evidence, not survey)**

```bash
grep -rn "function(nano_ros_add_node\|function(nano_ros_add_executable\|function(nano_ros_entry\|function(nros_components_register_node\|function(nano_ros_auto_add_library\|function(nros_generate_interfaces\|function(nano_ros_use_board" \
  modules/nros --include=*.cmake --include=CMakeLists.txt
```

Decision table:
- `nano_ros_add_node` + `nano_ros_add_executable` still defined → NO CMake migration; go to Task 4.
- Only new verbs exist → migrate: `nano_ros_add_executable(actuation_entry BOARD zephyr MODEL "src/controller_bringup/config/system_model.yaml" TYPED)` becomes `nano_ros_entry(NAME actuation_entry MODEL "src/controller_bringup/config/system_model.yaml" TYPED PANIC halt)` (keep MODEL spelling this round — LAUNCH+BRINGUP migration is a separate follow-up; `PANIC halt` preserves old halt-on-panic behavior per breaking change #4). `nano_ros_add_node(controller CLASS controller_pkg::Controller TYPED SHAPE rclcpp HEADER controller_pkg/controller.hpp SOURCES …)` becomes `nano_ros_auto_add_library` + `nros_components_register_node(<lib> PLUGIN controller_pkg::Controller EXECUTABLE controller SHAPE rclcpp TYPED)` — read the verb's signature in the submodule's cmake source and the book's workspace-cpp chapter before writing the call; then fix the target name expected at `controller_pkg/CMakeLists.txt:91` to match what the new verb creates.

- [ ] **Step 2: Read the migration recipe shipped for exactly this**

Read `modules/nros/book/src/porting/board-crate-import.md` section "Migrating an existing hand-glued consumer" and follow any step that applies to build.sh/CMake that this plan hasn't covered. Log deltas in the wall table (Task 6).

- [ ] **Step 3: Configure-only smoke**

```bash
./build.sh -c && ./build.sh 2>&1 | tee /tmp/claude-1000005/-home-aeon-repos-autoware-safety-island/99f302e8-47a5-493f-830e-0e7db99cd859/scratchpad/build-wall-1.log
```

Expected: reaches compilation (CMake configure passes). Each configure-time FATAL is one wall — fix per decision table above, re-run. `system_model.yaml` schema rejection → re-resolve: check play_launch version pinned in the CLI's Cargo.lock, re-run `play_launch resolve launch/system.launch.xml --system system.toml` per `controller_bringup` README/comments.

- [ ] **Step 4: Commit (one commit per coherent wall fix)**

```bash
git add -p && git commit -m "fix(phase-3): <wall> — <one-line what changed>"
```

### Task 4: C++ compile fixes — API drift sweep

**Files:**
- Modify (as greps dictate): `actuation_module/include/common/node/node_nros.hpp`, `actuation_module/include/common/clock/clock.hpp`, `actuation_module/src/controller_pkg/src/controller.cpp`, test programs under `actuation_module/test/`

**Interfaces:**
- Consumes: Task 3's configuring build.
- Produces: `zephyr.elf` links for the default target.

- [ ] **Step 1: Pre-emptive audit of the two known silent traps (before compiling further)**

```bash
grep -rn "\.spin(" actuation_module/ --include=*.cpp --include=*.hpp
grep -rn "nros_platform_clock_ms\|nros_platform_clock_us" actuation_module/
```

Any `spin(<number>)` bounded-spin call → change to `spin_for(<number>)`. Any removed clock fn → `nros_platform_clock_ns()/1000000` (ms) or `/1000` (us). If greps return nothing, record that and move on.

- [ ] **Step 2: Drive the build to link**

```bash
./build.sh 2>&1 | tee /tmp/claude-1000005/-home-aeon-repos-autoware-safety-island/99f302e8-47a5-493f-830e-0e7db99cd859/scratchpad/build-wall-N.log
```

Fix compile/link walls one at a time. Known-likely ones and their fixes:
- Generated-header dir moved from `${CMAKE_BINARY_DIR}/src/autoware/autoware_msgs/nano_ros_cpp` → find the actual output dir (`find build -name '*.hpp' -path '*nano_ros*' | head`), fix `controller_pkg/CMakeLists.txt:110`.
- Duplicate FFI symbols now per-package crates — the `--allow-multiple-definition` workaround at `actuation_module/CMakeLists.txt:44` may be droppable; try removing it ONLY after the build links with it present (separate commit, revert if link breaks).
- `NROS_COMPONENT` / `NROS_PKG_NAME` contract changes → read `modules/nros/packages/api/nros-cpp/include/nros/component_node.hpp` at the pin and adapt `controller.cpp:8-23`.

Success: `build/actuation_module/zephyr/zephyr.elf` exists.

- [ ] **Step 3: Commit per wall**

Same pattern as Task 3 Step 4.

### Task 5: Overlay conf audit + test-mode builds

**Files:**
- Modify: `actuation_module/nano_ros_overlay.conf`

**Interfaces:**
- Consumes: linking build from Task 4.
- Produces: all four CI build modes green locally.

- [ ] **Step 1: Fix the stale codegen-tool line**

`nano_ros_overlay.conf:20` points at the retired devcontainer path. Replace:

```
CONFIG_NROS_CODEGEN_TOOL=""
```

(empty — resolution comes from `-D_NANO_ROS_CODEGEN_TOOL` which build.sh always passes; a wrong non-empty path is a trap for anyone building without build.sh). If Kconfig rejects empty string default semantics, delete the line instead.

- [ ] **Step 2: Knob audit (knobs went live upstream — #316)**

Confirm build.sh env exports still exist and win (environment-over-Kconfig): `NROS_MAX_PARAMETERS=256`, `NROS_EXECUTOR_MAX_CBS=16`, `NROS_SUBSCRIPTION_BUFFER_SIZE=16384` at `build.sh:352-358`. Cross-check names still read by the nros build: `grep -rn "NROS_MAX_PARAMETERS\|NROS_EXECUTOR_MAX_CBS\|NROS_SUBSCRIPTION_BUFFER_SIZE" modules/nros --include=*.rs --include=*.cmake | head`. Renamed knob = wall; fix build.sh export name.

- [ ] **Step 3: Build all CI modes (clean between switches — stale cache rule)**

```bash
./build.sh -c && ./build.sh                      # mode 0: full controller
./build.sh -c && ./build.sh --unit-test
./build.sh -c && ./build.sh --dds-loopback-test
./build.sh -c && ./build.sh --can-output-test
```

Each must produce `build/actuation_module/zephyr/zephyr.elf`. Test sources use the polling shim (`node_nros.hpp`) and idlc-style compat headers (`"SteeringReport.h"` + `autoware_vehicle_msgs_msg_SteeringReport` C names in `test/dds_pub.cpp`, `test/dds_loopback_test.cpp`) — if the new codegen dropped idlc-name-compat headers, that is a wall: check what compat surface `modules/nros/zephyr/cmake/nros_rmw_cyclonedds.cmake` generates now and adapt includes.

- [ ] **Step 4: Commit**

```bash
git add actuation_module/nano_ros_overlay.conf build.sh
git commit -m "fix(phase-3): overlay conf codegen-tool cleanup + knob audit for the eace2885 pin"
```

### Task 6: FVP runtime smoke + docs + wall ledger

**Files:**
- Modify: `docs/roadmap/phase-3-modern-nano-ros-migration.md` (append bump section)
- Possibly modify: `.github/workflows/build-ci.yml` (only if bootstrap steps changed CI needs)

**Interfaces:**
- Consumes: ELFs from Task 5.
- Produces: verified boot markers; documented wall ledger (the "fix nano-ros frictions" deliverable).

- [ ] **Step 1: FVP availability**

```bash
ls tools/fvp/FVP_Base_AEMv8R_11.31_28/bin 2>/dev/null || echo "FVP missing"
```

If missing, fetch exactly as CI does — read `.github/scripts/run-zephyr-fvp-ci.sh` for the sha-pinned Arm CDN URL and mirror it into `tools/fvp/`.

- [ ] **Step 2: Boot the full controller image**

```bash
set -x ARMFVP_BIN_PATH (pwd)/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin   # fish
./build.sh -c && ./build.sh
west build -d build/actuation_module --target run 2>&1 | tee /tmp/claude-1000005/-home-aeon-repos-autoware-safety-island/99f302e8-47a5-493f-830e-0e7db99cd859/scratchpad/fvp-boot.log
```

Expected markers (same greps CI uses): "Starting Controller Node", "Controller Node Started", "Actuation Safety Island is Live". Interactive tip from the runbook: add `-C cache_state_modelled=0` via `ARMFVP_EXTRA_FLAGS` for speed. Timeout without markers = runtime wall: capture log, bisect-friendly note (see HEAD caveat #11 — if suspect, retry with pin a few commits before the #260 SMP series and record).

- [ ] **Step 3: Unit-test + loopback images on FVP**

```bash
./build.sh -c && ./build.sh --unit-test        # run: expect "=== All Tests Passed ==="
./build.sh -c && ./build.sh --dds-loopback-test  # run: expect "DDS loopback test passed"
```

Run each via the same `west build --target run` invocation.

- [ ] **Step 4: Document the bump + wall ledger**

Append to `docs/roadmap/phase-3-modern-nano-ros-migration.md`: new pin, submodule adoption decision (lockstep rule), table of every wall hit (symptom → root cause → ASI-side fix → whether it's a nano-ros friction worth an upstream issue). Frictions worth filing upstream get one line each; do NOT edit `~/repos/nano-ros`.

- [ ] **Step 5: Final commit**

```bash
git add docs/roadmap/phase-3-modern-nano-ros-migration.md
git commit -m "docs(phase-3): eace2885 bump ledger — walls, fixes, upstream frictions"
```

- [ ] **Step 6: Verify FreeRTOS paths untouched**

```bash
git diff a76b63f..HEAD --stat -- actuation_module/freertos actuation_module/freertos_s32z2 | tail -3
```

Expected: no new changes from this plan's commits (nano-ros-free paths stay green by construction).

---

## Self-review notes

- Spec coverage: rebase (none needed — constraint), submodule (Task 1), workflow alignment (Tasks 1/2 + Task 3 Step 2 recipe read), pin bump (Task 1), code fixes (Tasks 3–5), friction logging (Task 6). CI workflow file untouched unless bootstrap deltas demand it (Task 6).
- Deliberately out of scope: LAUNCH+BRINGUP entry migration (follow-up), zephyr-s32z on nano-ros (upstream board bundle deleted — G7 stands), FreeRTOS-on-nano-ros (W5), Zephyr 4.4 line.
- Placeholder honesty: Tasks 3–4 are wall-driven; where exact code can't be known pre-build, the plan gives the decision procedure + exact grep evidence steps instead of fabricated diffs.
