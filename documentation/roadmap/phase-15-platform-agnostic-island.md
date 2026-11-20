# Phase 15 - a platform-agnostic island on nano-ros

Status: in progress (2026-11-16). P1, P2 done; P3 done with interim
workarounds waiting on nano-ros; P12 done: the default build runs the
released nano-ros 0.6.0-nros11. The work that needs nano-ros past nros11 (a
main pin, the parameter workarounds' removal, P4) waits on branch
`nano-ros-next` for nros12. nano-ros gaps filed as issues 4005-4018.
On branch `nano-ros-next` nano-ros is pinned at main 1866c0594f (2026-11-20)
and the CLI is built from source; there P4 is done too, and the P9 `fabsl` and
Eigen items and the P11 S32Z Zephyr board item (see "Dropped on
nano-ros-next", below).

Goal: leave the island with application code only. What still ties it to
a platform after phase 14 moves to nano-ros (rclcpp API, platform, board
packages, `nros run`), so that:

- `asi_common` has no `PLATFORM_*` dispatch, and the controller builds for
  the `linux` board;
- the contract census builds (`entities = "census"` replaces
  `[census] on_missing = "warn"`), so nano-ros checks
  `launch/system.contract.yaml` against the code and derives the pools;
- `build.sh` and the CI scripts shrink to `nros build <id>` /
  `nros run <id> --expect`.

Branches: as in phase 14. Attempts land on `nano-ros`; each finished step
is folded into `nano-ros-migration` as one clean commit whose tree equals
`nano-ros` at that point.

Every step lands green on the five run lanes (posix, posix-carla, an536,
fvp, fvp-tap) before the next. The link-only lanes (s32z, freertos-s32z2)
must still link.

## What still ties the port to a platform

Read on `nano-ros-migration` 7f23105 at nano-ros pin 5b9e8844a4.

1. `asi_common` is a hand-written platform layer: 20 `include/platform/*`
   headers with `PLATFORM_*` dispatch, the logging shim, the clock and
   SNTP, Zephyr network bring-up, the CAN backends, pthread shims. This is
   why the census cannot build a host image.
2. `build.sh` (738 lines) and the CI scripts carry workarounds. Two are
   already fixed in nano-ros at the pin (`profile` on the CMake road, issue
   3899; the SDK gcc lookup, issue 1117); the rest are nano-ros gaps.
3. Dead or orphaned trees: the `freertos_x5h` lane, the asi_common s32z2
   headers, `cmake/actuation_core.cmake`, `src/autoware/autoware_msgs/*.idl`,
   `autoware_osqp_interface`, dead Kconfig symbols.

## nano-ros issues this phase depends on

| issue | gap | step |
|---|---|---|
| 4005 | consumer evidence for tracker issues 0758 (SNTP re-acquire, epoch failure policy), 0772 (FreeRTOS epoch), 2165 (Zephyr SMP log stops after four records; closed 2026-11-19 as not reproducing at 93368ca929, see P4) | P4, P5 |
| 4006 | `nros-toolchain.toml` cannot pin a git commit | P11 |
| 4007 | fvp runner: model parameters (SMSC NIC, tap hostbridge, uart out_file) | P10, P11 |
| 4008 | carry the Zephyr CTF app_marker and k_thread_priority_set patches | P11 |
| 4009 | public trace marker through the installed trace sink | P11 |
| 4010 | `RCLCPP_*_THROTTLE` (steady clock) and `RCLCPP_*_ONCE`; fixed at the pin (PR 4042) | P4 |
| 4011 | board network file for Zephyr images (`NET_CONFIG_*`); fixed at the pin (issue 2679, 41ffa35b7f); the FVP images state their address in a board network file (P6) | P6 |
| 4012 | board-owned CAN frame driver | P7 |
| 4013 | SDK Eigen 3.4 for arm-none-eabi; closed won't fix: nano-ros ships no general-purpose C++ library, so the island brings its own (`src/eigen`, a workspace package) | P9 |
| 4014 | Zephyr board descriptor for S32Z270 RTU0 (`s32z2xxdc2@D`); fixed on main (PR 4086), used on nano-ros-next | P11 |
| 4015 | s32z270-freertos RTD variant (GIC port, NETC netif); the variant is on main (PR 4096), without the NETC netif | P11 |
| 4016 | public opt-out for a host helper executable in a board build; fixed at the pin (issue 2678, 67ba69c7ef: `nano_ros_add_plain_executable`), used on nano-ros-next | P9 |
| 4017 | fvp-aemv8r-smp newlib lacks `fabsl`; fixed on main (PR 4039), used on nano-ros-next | P9 |
| 4018 | bug: `declare_parameter` past the store capacity silently returns the default; fixed at the pin (PR 4030: the boot stops) | P3, P8 |

Related, not ours: 3761 (CAN FD E2E profile and a FlexCAN helper).

## Pin on nano-ros-next

nano-ros main 1866c0594f (2026-11-20, 2b6fe0c). Over 011a9c4c5b it adds PR
4423 (issue 2758: the RMW ABI enums are pinned int-wide, so C and Rust agree
on their layout on arm-none-eabi) and PR 4430 (issue 2761: every RTOS runner
takes `nros_board_network_wait` as a weak reference). Cyclone is unchanged.
Local lanes on it: POSIX exit 0, AN536 exit 0 (controller Live at 8.9 s
model time; unit and loopback tests pass).

Before that, nano-ros main 011a9c4c5b (2026-11-20, d3a2941). Over 93368ca929 it adds PR
4414 (issue 2755): arm-none-eabi enums are one byte, and Cyclone's generic
QoS (plist) code treated enum fields as four, so validation read heap
padding and intermittently refused the AN536 controller's parameter
services (about 9 boots in 69 before, 0 in 50 after; Cyclone 05b3c9eda5 in
`nros-sdk.lock`). It also adds PR 4415 (issue 2753: `nros run --base-paths`
keeps the image argument). Local AN536 lane on it: controller Live at
11.9 s model time with no parameter-service error. CI run 44655818128
(d3a2941) green on all three lanes.

Before that, nano-ros main 93368ca929 (2026-11-19, 5b600fe). Over 9afb5c8a19 it adds the
nano-ros issue 2704 fix (PRs 4223, 4278): the Zephyr road now generates the
runtime's own `rcl_interfaces` types for Cyclone, so the FVP image's six
parameter services come up. At 9afb5c8a19 the image booted and printed
"parameter services could not be created for node /controller ...
Transport(Unsupported)" and ran without them. Booted on the FVP
(user-mode networking) at 93368ca929: no such line and no descriptor
overflow, "parameter store: 164 slots ... carved", Live, and the
controller logging through 121 s. `nros-sdk.lock` records the sources and
system packages this build resolved.

Before that, nano-ros main 9afb5c8a19 (2026-11-18). Over a49a8dacaf it adds PR 4190
(575f694215, issue 2689: `SourceMetadata` reads the schema v6 probe
sidecar and a stamp failure is loud), which fixes the configure break
below; the Zephyr FVP controller image configures, links and boots on it
(P6). play_launch and rlm are unchanged; `nros build --dry-run` resolves
fvp, fvp-tap and s32z. CI run 44262797472 (9be8383) is green on all
three lanes.

Before that, a49a8dacaf (2026-11-18). Over 5871cd6e45 it adds PR 4016
(67ba69c7ef, issue 2678: `nano_ros_add_plain_executable`), 4011
(e7827f2195 / 41ffa35b7f, issue 2679: a Zephyr board network file renders
into `NET_CONFIG_*`), 4018 (f3d185fd44: a launch value of another type
than its declaration stops the boot), the CAN frame driver's Zephyr backend
(7e9088d214, 61364bbd78) and issue 2650 (d8c4a1383f, a49a8dacaf: the
probe records the longest parameter description). play_launch and rlm are
unchanged, so the contract needs no migrate; `nros build --dry-run`
resolves fvp, fvp-tap and s32z.

Broken at a49a8dacaf (nano-ros, fixed by 4190): the Zephyr FVP
controller configure stops in `NanoRosPromise.cmake:402` ("this image's
entity inventory was composed after this configure's readers ran, and no
`nros configure` seeded them"). Cause: since d8c4a1383f the C++ metadata
probe emits `parameter_description_max_len` /
`parameter_constraints_max_len`, but the CLI's `SourceMetadata`
(`nros-cli-core/src/orchestration/source_metadata.rs`,
`deny_unknown_fields`) has neither field, so `stamp_provenance` fails to
parse the sidecar and `metadata_refresh.rs` drops the error (`let _ =`).
`src/controller_pkg/metadata/controller.json` is rewritten with no
`provenance` on every `nros configure`, reads stale at once, and the
image's configure takes no seed. zephyr-s32z stops the same way. CI run
44203831657 (c35a136): FreeRTOS POSIX and FreeRTOS AN536 green, Zephyr FVP
red at this configure in phase 1 (job 134464551728).

Before that, 5871cd6e45 (2026-11-17), past the nros11 tag (09219edc75).
Over e845661f0b it adds PR 4080 (89d696e5d7, issue 2652: `nros build`
passes its own `-D_NANO_ROS_CODEGEN_TOOL` on every configure it starts),
4039 (f29f50aa0d, issue 2630: `fabsl` / `copysignl` in nano-ros's Zephyr
`<cmath>` on newlib aarch64), 4086 (3ceb48628d, issue 2631: board
`s32z270-rtu0-zephyr`, the revision in `west_board`), 4066 (3c2e8cf685:
board-facts uses `nros build`'s lookup and finds workspace board packages),
4096 (5871cd6e45, issue 2632: board `s32z270-freertos-rtd`), 4090
(`PYO3_PYTHON` pin), 4095 and 4081 (play_launch 0.36.0, rlm v0.3.27; the
contract needed no edit). The workarounds these made dead went, each its own
commit (below).
CI run 43968504048 (adc0cab) is green on all three lanes: Zephyr FVP 24
min, FreeRTOS POSIX 13, FreeRTOS AN536 13.

Before that, e845661f0b (2026-11-17): over ea94566e87 it adds PR 4063 (phase-567 W4, an island-shaped workspace in
nano-ros's merge queue) and 7f2e306c13 (issue 2644, a C + Rust image with no
C++ source configures and seeds its bounds); the island needed no change for
either.

Earlier on this branch, ea94566e87 (2026-11-16): a
declaration with no store slot stops the boot (PR 4030, issue 2634), a launch
list parameter seeds as a typed array (PR 4034, 2638), `RCLCPP_*_THROTTLE` on
the clock argument plus `_ONCE` / `_SKIPFIRST` (PR 4042, 2636),
`list_parameters` past 64 names with rclcpp's prefix and depth filtering
(PR 4043, 2639), and a metadata probe store of 1024 (PR 4044, 2640). Every
param file and launch value was re-checked for the coming type-mismatch
refusal: every double is a float literal, every integer an integer.

### How nano-ros-next is built and tested

- `nros_cli_select` (scripts/nros-cli.sh) with `NROS_DEV_CLI` unset compares
  `modules/nros` with the tag of the release `nros-toolchain.toml` pins
  (fetching that one tag when a narrow clone lacks it). Here the two differ,
  so it builds the CLI and the launch resolver from `modules/nros` and logs
  `nros-cli: modules/nros is <sha>, not release nros-<v> (<tag sha>):
  building the source CLI`. No flag is needed: `./build.sh` and every CI lane
  take the source path on this branch, and the release path on `nano-ros`,
  where the submodule is the tag. `NROS_DEV_CLI=1` forces source,
  `NROS_DEV_CLI=0` forces release (and refuses this checkout).
- `nros-toolchain.toml` keeps `0.6.0-nros11`: it is only the comparison point
  until nros12; the submodule and `west.yml` move together (LOCKSTEP).
- After a pin bump: `git -C modules/nros submodule update --init
  packages/cli/third-party/play_launch`, then `just setup-launch-resolve` in
  `modules/nros` (or let the source path's own cargo build do it).
- CI: `build-ci.yml` runs on push to `main` only, so a `nano-ros-next` run is
  dispatched: `gh workflow run build-ci.yml -R
  NEWSLabNTU/autoware-safety-island --ref nano-ros-next`. At e845661f0b run
  43919140736 is green on all three lanes (Zephyr FVP 22 min, FreeRTOS
  POSIX 11, FreeRTOS AN536 11), each on the source CLI.
- The source CLI is built once per run: a select exports
  `NROS_CLI_SOURCE_BUILT=<commit>` on a clean checkout, and a child select
  (build.sh under a lane) of the same commit skips cargo. Without it every
  select rebuilt the CLI and resolver for about 2 min (pyo3 reruns on the
  PATH the select changes; cargo-nano-ros's build script watches all of
  `packages/`, target/ included); the Zephyr lane selects seven times and
  took 35 min.
- The one contract (`controller_bringup/launch/system.contract.yaml`) is
  already in rlm v0.3.27's spellings: it parses, and `migrate` finds 0
  edits (a node's own `paths:` keep the word), so nano-ros PR 4081 needs no
  island change.
- `build.sh` no longer states `-D_NANO_ROS_CODEGEN_TOOL=<cli>` on an
  `nros build` configure (PR 4080). The Zephyr test programs keep it: there
  `build.sh` runs `west build` itself, not `nros build`.

### Dropped on nano-ros-next (pin a49a8dacaf)

Each is done on `nano-ros-next` only; on `nano-ros` it waits for nros12.

- c35a136, `controller_pkg/CMakeLists.txt`: the private
  `_NROS_IN_IMAGE_ADD_EXECUTABLE` switch around `can_vcan_sender`'s
  `add_executable` (P9, issue 4016, PR 4016's
  `nano_ros_add_plain_executable`). `./build.sh --platform freertos-posix
  --can-output-test` builds the sender as a plain x86-64 PIE with its own
  `main` and no nros entry symbol; it runs and reports the missing
  `SAFETY_ISLAND_CAN_IFACE`.

- cdc5c01, `build.sh`: the `-D_NANO_ROS_CODEGEN_TOOL` on the Zephyr
  controller and FreeRTOS `nros build` configures (PR 4080). The existing
  `build/zephyr-fvp` and `build/freertos-posix` directories build.
- 6d3d71e, `asi_common/CMakeLists.txt`: the `fvp_baser_aemv8r`
  `-Dfabsl(x)=...` define (P9, issue 4017, PR 4039). zephyr-fvp rebuilds
  its 34 C++ units and links.
- 940e06f, 57d3fb1, b8ef477, `src/eigen/` (new), `asi_common/CMakeLists.txt`
  (the `asi_eigen` target, the host Eigen lookup and the configure-time
  copy-and-patch, removed), `src/autoware/` (P9, issue 4013). nano-ros
  closed 4013 won't fix: it ships no general-purpose C++ library, and a
  package finds and links its own as it would without nano-ros. So
  `src/eigen` is a workspace package: upstream Eigen 3.4.0's headers
  (tarball sha256 b4c19846...6e626) with the psincos patch applied in the
  tree (`patches/` keeps it as the record), a `cmake/Eigen3Config.cmake`
  defining `Eigen3::Eigen`, and a `CMakeLists.txt` that sets `Eigen3_DIR`
  there and calls `ament_package()`. `autoware_controller_libs`
  `<depend>`s on `eigen` (so the image closure configures it first) and
  writes upstream's `find_package(Eigen3 3.4 REQUIRED)`. It does not need
  the pin: the same change works on `nano-ros`. Built: freertos-an536,
  zephyr-fvp, freertos-posix, and zephyr-s32z on a fresh directory; each
  configure caches `Eigen3_DIR=src/eigen/cmake`, none reads
  `/usr/include/eigen3`. zephyr-s32z text / data / bss 1948912 / 43964 /
  4595678 (was 1947888 / 43964 / 4595678): `.text` unchanged, rodata +1024
  (Eigen's assert `__FILE__` strings carry the longer path). CI run
  44083208345 green (an536, posix, fvp).
- Checked, kept: the controller_pkg `add_subdirectory` fallbacks
  (`:18-23`). Without them the metadata probe fails: its generated
  `CMakeLists.txt` adds `src/controller_pkg` alone, not the package's
  `<depend>` closure, so `controller_node.hpp` cannot find
  `autoware/trajectory_follower_base/control_horizon.hpp` and `nros build
  freertos-posix` stops ("1 metadata probe(s) failed"). The `TARGET app`
  block (`:65-70`) is not a fallback but the Zephyr entry's include
  context; not touched. `src/autoware` gets the same fallback for `src/eigen`.
- a3e3df1, `src/s32z270_zephyr_board/` (removed), `build.sh`
  (`-DBOARD_REVISION=D`, the `NROS_EXTRA_BOARD_PATH` export),
  `system.toml` and the S32Z docs (P11, issue 4014, PRs 4086 and 4066):
  `[image.s32z]` names nano-ros's `s32z270-rtu0-zephyr`. The image still
  states what that board leaves to it: `CONFIG_MAIN_STACK_SIZE=32768` and
  the C++ runtime (`zephyr/prj-actuation.conf`; the S32ZE SoC default 1024
  wins otherwise), and `hal_nxp` in `actuation_module/west.yml` (not in
  nano-ros's west allowlist). Read back from the build: the configure says
  `Board: s32z2xxdc2, Revision: D`; `zephyr.dts` chooses `uart9` (Zephyr's
  revision-D overlay), `can0` (the RTU0 devicetree) and `sram2` (nano-ros's
  overlay). zephyr-s32z links on a fresh directory: text / data / bss
  1947888 / 43964 / 4595678, RAM 89.72% of 7 MiB (nros11, P12: 1954456 /
  43972 / 4556655).
- Not switched: `[image.s32z2]` to `s32z270-freertos-rtd`. That variant
  refuses a configure without both `NXP_FREERTOS_S32ZE_DIR` and
  `S32_RTD_PATH`, and `s32z2_board_glue` stops the configure when
  `S32_RTD_PATH` is set (its RTD source wiring is the hardware bring-up's,
  phase-4 W5.b item 5). So the switch lands with that wiring, on a host with
  the NXP trees: the image (or a second one) names `s32z270-freertos-rtd`;
  `build.sh` passes `NXP_FREERTOS_S32ZE_DIR` (what
  `scripts/provision-nxp-freertos.sh` stages) instead of `FREERTOS_DIR` /
  `FREERTOS_PORT`; the pthread shim keys its `xTaskCreate*Fpu` choice on the
  variant's `nrosconfigTASK_CREATE_FPU` (its `config-rtd/FreeRTOSConfig.h`)
  instead of the `ASI_S32Z2_NXP_PORT` switch in `asi_common/CMakeLists.txt`.
  The s32ct_config submodule and the NXP RTD are not on this host, so none
  of it can be built here.
- Pin 1866c0594f, 7cfb9bc, the seven `src/autoware/*/CMakeLists.txt`:
  the add-once guard (`if(TARGET <self>) return()`) at the top of each
  Autoware package (P9). nano-ros issue 2756 (00dbf47f37): the generated
  Zephyr application adds an image's packages in `<depend>` order, as the
  FreeRTOS road's `ORDER_FROM_DEPENDS` does, so a package's own line comes
  before any dependent's fallback looks for it. The `add_subdirectory`
  fallbacks stay (see "Checked, kept" above). Local lanes without the
  guards (2026-11-20): `run-freertos-posix-ci.sh` exit 0,
  `run-freertos-an536-ci.sh` exit 0 (controller Live at 8.9 s model time),
  `run-zephyr-fvp-ci.sh` exit 0 (all six phases; phase 1 controller Live,
  `prio=9`; phase 5 builds the fvp-tap controller image).
- Pin 1866c0594f, 35229f3, `build.sh`, `controller_bringup/system.toml`
  (P11, issue 4007, nano-ros issue 2629, cbbcf089a6): the controller
  images' FVP model parameters come from rows, not `ARMFVP_EXTRA_FLAGS` in
  the environment. fvp-aemv8r-smp's `[board.run.fvp] params` states the
  SMSC 91C111 enable and promiscuous mode; the four tap images state
  `run.nic = { tap = "tap0" }` (host bridge TAP mode); the four trace
  images state `run.fvp.params = ["bp.pl011_uart1.out_file=trace.ctf"]`,
  relative to the build directory the model runs in (the old default
  path). `nros build` hands them to `armfvp.cmake` as
  `-DARMFVP_EXTRA_FLAGS`. `TRACE_OUT_FILE` is gone (its one caller,
  `capture-fvp-trace.sh`, passed the default); `FVP_TAP_INTERFACE` other
  than tap0 now stops a controller build with a pointer to the rows.
  Read back from the generated `run_armfvp` command: fvp ends
  `-C bp.smsc_91c111.enabled=1 -C bp.smsc_91c111.promiscuous=1`; fvp-tap
  adds `-C bp.hostbridge.userNetworking=0 -C
  bp.hostbridge.interfaceName=tap0`; fvp-trace adds `-C
  bp.pl011_uart1.out_file=trace.ctf`. Local `run-zephyr-fvp-ci.sh` exit 0
  (six phases).
  Not covered: the Zephyr test programs (`build_zephyr_test`, the
  hand-written west application `test/zephyr_app`) are no bringup image,
  so no board or image row reaches them, and the board's
  `[board.run.fvp]` params are applied only on `nros build`'s west road.
  `build_zephyr_test` states the same parameters itself, now as a
  `-DARMFVP_EXTRA_FLAGS` cache list (always passed) instead of the
  environment, and keeps `FVP_TAP_INTERFACE` (the tap CI lane's CAN
  tunnel program reads it). They go when the test programs become images
  (P10's FVP half). `scripts/run-tap-demo.sh` still exports `-C
  cache_state_modelled=0` for interactive demo runs; Zephyr's
  `armfvp.cmake` appends the environment after the rows, so it still
  applies.
- CI run 44738961021 (35229f3, both entries above) green on all three
  lanes; local FreeRTOS POSIX and AN536 lanes rerun on 35229f3, exit 0
  (AN536 controller Live at 9.4 s model time). `can_vcan_sender` was
  already `nano_ros_add_plain_executable` (c35a136); no use of the private
  `_NROS_IN_IMAGE_ADD_EXECUTABLE` is left.

What remains of P9 and P11 after this:

- P9: the `add_subdirectory` fallbacks in controller_pkg and the seven
  Autoware packages, until the metadata probe configures a node package's
  workspace `<depend>`s (a nano-ros change, not filed). The Autoware
  packages' add-once guard is gone (nano-ros issue 2756, see below).
- P11: the NETC netif glue (`s32z2_board_glue`; nano-ros's RTD variant has
  none, issue 4015 stays open for it); the NXP `port.c` Thumb-resume patch
  (`vendor_patched/port.c.patch`), NXP-licensed source the island cannot
  hand upstream as is; the RTD switch above; one pin and the west import
  (4006); the Zephyr patches and trace marker (4008, 4009). FVP model
  parameters come from the board and image rows (4007, see below), except
  for the test programs, which are no image.
- P7 (CAN behind one interface) still waits on the board-owned CAN frame
  driver (4012).

## Steps

### P1. Cleanup, no behaviour change - S

- What: delete dead files and config. Decide the x5h lane: delete it and
  its ifdefs, or move it to a branch. Use the public parameter API in the
  unit test. Use the codegen's `Msg::CONSTANT` spelling.
- Files: `actuation_module/cmake/actuation_core.cmake`;
  `src/autoware/autoware_msgs/msg/*.idl`; `src/autoware/autoware_osqp_interface/`
  and `qp_solver_osqp.cpp`; `src/asi_common/include/platform/freertos/s32z2/`
  except `pthread.h`; asi_common Kconfig `DDS_DOMAIN_ID`,
  `DDS_NETWORK_INTERFACE`, `DDS_LOG_LEVEL`, `THREAD_STACK_SIZE`,
  `MAX_PTHREAD_MUTEX_COUNT` and their assignments in `prj-fvp.conf`,
  `prj-s32z.conf`, `freertos_config_generated.h.in`; `choice
  CONTROL_CMD_OUTPUT_MODE` (the launch arg `control_output` owns it);
  `freertos_x5h/`, `.github/workflows/x5h-freertos-ci.yml`,
  `PLATFORM_FREERTOS_X5H` code in `controller_node.cpp`; the second Eigen
  patch copy; `test/unit_test.cpp:102` (`rclcpp::detail::node_param_set`
  -> `set_parameter`); `asi_common/include/autoware/autoware_msgs/messages.hpp`
  (`OperationModeState::UNKNOWN`).
- Depends on: nothing.
- Done when: all lanes green, `rg PLATFORM_FREERTOS_X5H` and
  `rg PLATFORM_FREERTOS_S32Z2` return nothing.
- Status: done (2026-11-16).
  - x5h: deleted (it was unbuilt, absent from build.sh, its CI stale). Gone
    with it: `.github/workflows/x5h-freertos-ci.yml`, the `rcar_bsp` and
    `lwip` submodules, `asi_common/include/platform/freertos/x5h/`, the
    controller's `PLATFORM_FREERTOS_X5H` si_channel fault input, the two
    x5h host tests (`test_rpmsg_netif_core.c`, `test_si_channel.c`), the
    second Eigen patch copy, `cmake/actuation_core.cmake`. Git history keeps
    the lane.
  - Deleted, never compiled: `autoware_msgs/msg/*.idl`,
    `autoware_osqp_interface/`, `qp_solver_osqp.cpp`; the s32z2 headers
    except `pthread.h` (the NETC bring-up's `lwip_init.h` moved to
    `s32z2_board_glue/board/`, next to `lwip_bringup.c`).
  - Kconfig: `DDS_DOMAIN_ID`, `DDS_NETWORK_INTERFACE`, `DDS_LOG_LEVEL`,
    `THREAD_STACK_SIZE`, their conf assignments and FreeRTOS mirrors, gone.
    `choice CONTROL_CMD_OUTPUT_MODE` and `CONTROL_CMD_DDS_OUTPUT` gone; the
    launch arg `control_output` is the mode (it always overrode the choice:
    every image already ran the launch default `DDS_ONLY`), and Kconfig keeps
    `CONTROL_CMD_CAN_OUTPUT` as "build the CAN backend" (set by
    `prj-s32z.conf` and the CAN test confs). The `MAX_PTHREAD_MUTEX_COUNT`
    range override went too: Zephyr 3.7 states no range for it, so the
    override only added a cap (the confs assign 1024 and 64). The unused `output_dds_and_can.conf` test fragment went too.
  - `OperationModeStateMsg::AUTONOMOUS` replaces the legacy namespace-level
    constant; the unused `SIR_*` defines went; `unit_test.cpp` uses the
    public `set_parameter<T>()`.
  - Checks: `rg PLATFORM_FREERTOS_X5H` and `rg PLATFORM_FREERTOS_S32Z2`
    return nothing outside the roadmap. Host tests 5/5. CI run 43806537782
    (posix, an536, fvp incl. the test programs) green on 62f8a3a. Link-only
    lanes built locally; the s32z `.config` has
    `CONFIG_CONTROL_CMD_CAN_OUTPUT=y` and `..._TRANSPORT_NATIVE=y` as before.
  - Sizes (text / data / bss, bytes), before (f8904f5) -> after:
    s32z Zephyr 2104024 / 43984 / 4556707 -> 2104024 / 43984 / 4556643;
    s32z2 FreeRTOS 1710896 / 15880 / 2355588 -> 1710752 / 15880 / 2355580.

### P2. Fold the bringup - S

- What: one `[image_defaults]` for the knob rows, launch and the common
  `os_config` prefix; `[system] default_images`; `profile =
  "RelWithDebInfo"` on the FreeRTOS images; the S32Z revision in the board
  descriptor's `west_board`.
- Files: `src/controller_bringup/system.toml` (13 `[image.*]` blocks);
  `build.sh` (`-DCMAKE_BUILD_TYPE` :628, the gcc PATH `find` :616-620,
  `-DBOARD_REVISION=D` :475); `src/s32z270_zephyr_board/nros-board.toml`.
- Depends on: issue 3899 and 1117 (fixed in the pin).
- Done when: every knob value is stated once (the two
  `subscription_buffer_size` values stay per image on purpose), build.sh
  has none of the three lines, all lanes green.
- Status: done (2026-11-16), two items waiting on nano-ros.
  - `[image_defaults]` states `knobs.params.max_parameters = 164` and
    `knobs.executor = { max_cbs = 16, subscription_buffer_size = 16384 }`;
    an536 and s32z2 restate only `subscription_buffer_size = 65536`.
    `knobs.zephyr.heap_size = 8388608` stays on the eight FVP blocks:
    `[image_defaults]` reaches every image, and on s32z it would override the
    board package's 2 MiB. `os_config` stays per image for the same reason
    (the FreeRTOS images take none). A per-board-family default would fold
    both; nano-ros has none.
  - The nine `launch = "system.launch.xml"` rows went (`default_launch`
    names it). `[system] default_images = ["fvp", "freertos-posix", "an536"]`.
  - `profile = "RelWithDebInfo"` on the four FreeRTOS images replaces
    build.sh's `-DCMAKE_BUILD_TYPE` (3899 fixed): the configure now gets
    `-DCMAKE_BUILD_TYPE=RelWithDebInfo -DNROS_CARGO_PROFILE=nros-relwithdebinfo`
    from `nros build` itself (the configuration hash, and so the build
    directory, changes once).
  - The build.sh gcc PATH `find` went (1117 fixed): the configure prints
    `arm-none-eabi-gcc 13.2.1 via SDK store ... (pin 13.2.rel1, store
    package 13.2-nros5)`.
  - `prj-fvp.conf` dropped `CONFIG_MDIO`, the eth/mdio/phy init priorities
    (80/81/82) and `CONFIG_CHECK_INIT_PRIORITIES=n`: the nano-ros fvp board
    conf (`fvp_baser_aemv8r_fvp_aemv8r_aarch64_smp.conf`) states the same
    values. A configure-only build of `[image.fvp]` still resolves all five.
  - Waiting on nano-ros: `-DBOARD_REVISION=D` stays (the descriptor cannot
    carry `@D`: the Kconfig symbol nano-ros derives from `west_board` keeps
    the revision, and the board-file names flatten `@`; folded into the 4014
    fix). `NROS_EXTRA_BOARD_PATH` stays (see "To confirm", below).
  - Checks: `nros dev image leaf-system` renders (Kconfig fragment, knob
    defaults, image env) are byte-identical before and after for all 13
    images. CI run 43815518694 on 421f96e. Sizes (text / data / bss) are
    unchanged from P1: s32z 2104024 / 43984 / 4556643, s32z2 1710752 /
    15880 / 2355580.

### P3. Parameters to YAML - S-M

- What: the 149 parameter defaults move from C++ into the upstream Autoware
  param YAMLs (`lateral/mpc.param.yaml`, `longitudinal/pid.param.yaml`,
  `vehicle_info.param.yaml`), loaded by launch `<param from="..."/>` or
  `[image.<id>] params_files`. The compile-time profile becomes two YAML
  files or a launch arg. Optionally declare the input QoS in the contract
  so a bridge mismatch is a build-time refusal.
- Files: `src/asi_common/include/common/actuation_param_profile.h`;
  `pid_longitudinal_controller.cpp`, `mpc_lateral_controller.cpp`,
  `vehicle_info_utils.cpp`, `controller_node.cpp` (`declare_parameter`);
  `src/controller_bringup/launch/system.launch.xml`, `system.contract.yaml`.
- Depends on: launch `<param from>` / `params_files` (exist). 4018: until
  it is fixed, a parameter past `max_parameters` silently keeps the C++
  default, so keep the 164 count and add a boot check that reads back one
  YAML-only value.
- Done when: `actuation_param_profile.h` is gone, the YAML values reach
  the node on every lane (checked by `ros2 param get` on posix), all lanes
  green.
- Status: done (2026-11-16); one sub-item waits on nano-ros.
  - The values are `controller_bringup/config/`:
    `trajectory_follower_node.param.yaml` (16: control period, supervision
    timeouts and bounds, controller modes, the shared `ego_nearest_*`),
    `vehicle/vehicle_info.param.yaml` (9), `lateral/mpc.param.yaml` (54),
    `longitudinal/pid.param.yaml` (53) and
    `longitudinal/pid_profile_{after,before}.param.yaml` (5 each), loaded by
    `<param from="$(dirname)/../config/...">` in `system.launch.xml`; the
    launch arg `actuation_param_profile` (default `after`) picks the profile
    file. `actuation_param_profile.h` is gone; the inline `ctrl_period` and
    `mpc_prediction_horizon` moved into the files. The eight arg-bound
    parameters (`control_output`, the four supervision selections,
    `wheel_base`, `max_pitch_rad`, `min_pitch_rad`) stay inline. Every double
    is a float literal.
  - `.github/scripts/check-param-seeds.py` (posix CI phase 1d) refuses a
    declared parameter no file seeds (the four arrays included), a seeded
    one nobody declares, a param file value of another type than the
    declaration (so the coming nano-ros refusal of a mistyped launch value is
    safe to pin), and an image whose `max_parameters` is below the declared
    count (164 >= 149 on all 13).
  - The four steer-rate-limit arrays (`steer_rate_lim_dps_list_by_*`,
    `*_list_for_steer_rate_lim`) are in `lateral/mpc.param.yaml`: a launch
    list seeds as a typed array since nano-ros PR 4034.
  - No island boot check: a declaration past the store's capacity stops the
    boot in nano-ros (PR 4030) and the metadata probe's store holds 1024
    (PR 4044), so the `has_parameter("control_output")` check and the CI
    lanes' "Safety Island parameters incomplete" refusal went at the pin
    move to ea94566e87.
  - Waiting on nano-ros, interim in place:
    - the C++ `declare_parameter()` defaults stay (same values as the files):
      the per-component metadata probe constructs the node with no launch
      values, so a node declaring without defaults cannot be probed. Goes
      with P8's census or a probe that seeds the image.
  - Checks: on the posix image, all 149 parameters read back by name
    (`~/get_parameters`) have the same type and value as on the pre-P3 image.
    At ea94566e87 `ros2 param list /controller` on the posix image lists all
    149, and `ros2 param get` reads the four steer-rate-limit lists back as
    double arrays with the file's values. The resolved models give the
    `before` profile exactly the old `ACTUATION_PARAM_PROFILE_BEFORE` values
    (stopped_acc -0.4, emergency_acc -0.75, emergency_jerk -1.0, min_acc
    -0.75, min_jerk -1.0), and the CARLA image its three args, with every
    other value unchanged. Kept as found, for a later decision:
    `ego_nearest_dist_threshold` and `ego_nearest_yaw_threshold` are 0.0 (no
    TU ever gave them a default; upstream's common.param.yaml has 3.0 and
    1.046). Both S32Z270 entries seed the 145 values
    (`nros_cpp_declare_node_param`). Sizes (text / data / bss), P2 -> P3:
    s32z 2104024 / 43984 / 4556643 -> 2109592 / 43984 / 4556643 (+5568
    text, the seed table); s32z2 1710752 / 15880 / 2355580 -> 1716432 /
    15880 / 2355580 (+5680).

### P4. Logging - M

- What: `RCLCPP_*(get_logger(), ...)` in the controller; a thin `log_*` ->
  `RCLCPP_*` / `RCLC_LOG_*` mapping header for the vendored Autoware TUs
  (or restore their upstream calls); level from `knobs.log.max_level`.
  Throttle via `RCLC_LOG_*_THROTTLE` until 4010 lands.
- Files: `src/asi_common/include/common/logger/logger.hpp` (printk bypass
  :54-67, throttle map :117-188, `CONFIG_LOG_LEVEL` gating :71-114).
- Depends on: 2165 (via 4005) for removing the printk bypass; 4010 for
  upstream `RCLCPP_*_THROTTLE` call sites.
- Done when: no `std::map` / pthread mutex in the logger, CI greps still
  see "Actuation Safety Island is Live" through nros_log (printk only while
  2165 is open), all lanes green.
- Status: done (2026-11-16) at nano-ros ea94566e87 (4010 fixed by PR 4042);
  two sub-items wait on nano-ros.
  - Every throttled line is upstream's `RCLCPP_{INFO,WARN}_THROTTLE(logger,
    clock, 3000, ...)`, measured on the clock argument: the node's
    `get_logger()` / `*get_clock()` in `controller_node.cpp` (17 sites);
    `logger_` / `clock_` members taken from the node in
    `PidLongitudinalController` (3) and `MpcLateralController` (4), and
    `m_logger` / `m_clock` in `MPC` (1), as upstream Autoware holds them;
    `rclcpp::get_logger("mpc_utils")` and a steady `rclcpp::Clock` in the
    free function `calcNearestPoseInterp` (2). The window stays 3 s. The
    SNTP re-sync failure (`clock_resync.cpp`) is a plain `log_warn`: its loop
    already paces at `CONFIG_ASI_SNTP_RESYNC_INTERVAL_S` (>= 1 s).
  - `logger.hpp` lost `log_{info,warn}_throttle`, the `std::map` and the two
    pthread mutexes; `CONFIG_LOG_THROTTLE_RATE` went from the Kconfig, the
    FreeRTOS config header and asi_common's CMake. No site needed `_ONCE` or
    `_SKIPFIRST`: the island had no hand-rolled once or skip-first logging.
  - 2165 closed (2026-11-19) and the Zephyr printk bypass is gone (80ff827):
    every `log_*` line goes through nros_log on every target. Measured on the
    SMP FVP at 93368ca929 with the bypass compiled out: the island's lines,
    "Actuation Safety Island is Live" included, arrive as `<inf> nros:`
    records, 259 records through 121 s, no "log record(s) lost", and
    `nros_log::DISPATCH_GUARD`, `early::PENDING` and `early::LOST` read 0 at
    10, 31, 61 and 121 s (read over Iris, with a rodata cross-check against
    the ELF). nano-ros 139 closed 2165 on these runs and is hardening the
    Zephyr sink separately (no caller-stack buffer).
    Doable now, not done: the controller's own unthrottled `log_*` lines can
    become `RCLCPP_*(get_logger(), ...)` (they stayed `log_*` only for the
    bypass). It touches `controller_node.cpp`, so it waits for the P9 work
    there.
  - Waiting on nano-ros:
    - the level stays `CONFIG_LOG_LEVEL` (compile time: `log_debug` and
      `PROFILE_*` compile out below 2). `knobs.log.max_level` is a ceiling
      nros_log checks at run time, after the call site has evaluated its
      arguments, so it would not keep the per-cycle debug work out of the
      control loop.

### P5. Clock - M

- What: stamps from `now()` / `rclcpp::Clock`; input ages and timeouts on
  a steady clock (an SNTP step must not fire or mask the staleness gate);
  `CONFIG_NROS_SNTP_EPOCH` + `CONFIG_NROS_SNTP_SERVER` on Zephyr.
- Files: `src/asi_common/include/common/clock/clock.hpp`;
  `include/platform/zephyr/zephyr_clock.h`; `src/zephyr/board_network_hook.cpp`
  (SNTP retries, `std::exit(1)`); `src/common/clock/clock_resync.cpp`;
  `src/platform/freertos/wall_clock.cpp`; `controller_node.cpp` (`Clock::now()`
  users, `ASI_FREERTOS_WALL_CLOCK`).
- Depends on: 0758 (re-acquisition) and 0772 (FreeRTOS epoch), evidence in
  4005. `clock_resync.cpp` and `wall_clock.cpp` stay until those close.
- Done when: `zephyr_clock.h` and the hook's SNTP are gone, the CARLA run
  shows no stale-stamp rejection at `vehicle_cmd_gate`, all lanes green.

### P6. Network - S-M

- What: Zephyr `NET_CONFIG_*` instead of ASI's interface symbols and the
  manual DHCP wait; per-image `rmw_config` (and `CYCLONEDDS_URI` on host
  images) instead of `SI_DDS_INTERFACE`; FVP board fixes moved upstream.
- Files: `src/asi_common/src/common/net/network_config.cpp`; asi_common
  Kconfig `NET_IFACE*`; `board_network_hook.cpp` DHCP sleep;
  `src/asi_common/src/freertos_posix/si_dds_interface.cpp`;
  `run-freertos-posix-ci.sh:99-125`, `release.yml`; `prj-fvp.conf` (MDIO,
  ETH/PHY init priorities), `prj-actuation.conf` (network floor).
- Depends on: Zephyr net_config and `rmw_config` (exist); 4011 to state the
  address in a board network file. The S32Z VLAN tag stays a board hook.
  Moving the FVP board fixes upstream is filed when done, with measured
  values.
- Done when: `network_config.cpp` and `si_dds_interface.cpp` are gone, the
  FVP boot has no fixed 10 s DHCP sleep, the tap demo addresses unchanged.
- Status on nano-ros-next (pin 9afb5c8a19): the FVP address landed.
  `controller_bringup/zephyr/net-fvp.toml` (`[eth0] network = "fvp"`,
  `address = "dhcp"`; `[network.fvp] subnet = "172.20.51.0/24"`, `dhcp =
  true`) is first in the four user-mode FVP images' `os_config`;
  `CONFIG_NET_DHCPV4=y` and `CONFIG_NET_CONFIG_SETTINGS=y` moved out of
  `prj-actuation.conf` (the fragment check refuses any rendered symbol) into
  `prj-s32z.conf` with the 10 s initial delay, and into `prj-fvp-tap.conf`
  (settings only); `prj-fvp.conf` states
  `CONFIG_NET_DHCPV4_INITIAL_DELAY_MAX=2`; `network_config.cpp` skips
  interface 1 and `board_network_hook.cpp` the DHCP sleep when
  `CONFIG_NET_CONFIG_NEED_IPV4` is set (IFACE2 / VLAN stay for the S32Z);
  the FVP test programs take `test/zephyr_app/net-fvp.conf`, the rendered
  rows by hand. Booted on the FVP (user-mode networking): Zephyr's
  net_config leases 172.20.51.1 (netmask 255.255.255.0, router
  172.20.51.254, lease 86400 s) at 1.172 s model time, the island prints no
  "Waiting for DHCP" and is Live at 1.245 s; the subnet in net-fvp.toml is
  the one the model hands out. zephyr-s32z links at 9be8383 (fresh
  directory; `NET_DHCPV4=y`, `INITIAL_DELAY_MAX=10`, `NET_CONFIG_SETTINGS=y`
  from `prj-s32z.conf`, no `NEED_IPV4`): text / data / bss 1952800 / 43964
  / 4585134. CI run 44262797472 (9be8383) green: Zephyr FVP 24 min,
  FreeRTOS POSIX 13, FreeRTOS AN536 12. Still open for P6: the `network_config.cpp`
  paths the S32Z and the tap images keep.
- `SI_DDS_INTERFACE` is gone (19c14c1, user decision 2026-11-20): the POSIX
  images take their DDS interface from Cyclone's own `CYCLONEDDS_URI`, which
  nano-ros's hosted Cyclone reads when it opens the session.
  `si_dds_interface.cpp` (a strong `nros_board_network_wait()`) and its
  OBJECT library are removed; the POSIX lane selects by address and by name
  through the URI and keeps the refusal check (`nosuch0` fails the session,
  never "is Live"); the release smoke runs with Cyclone's choice and with
  `lo` named; guides, demo READMEs and the changelog show the URI form.
  The POSIX test images briefly included `<rclc/detail/main.h>` (a35c5aa)
  for nano-ros's weak no-op hook, because the FreeRTOS runner called it
  through a plain extern and their hand-written entries emit no default
  (the island hook had hidden it). nano-ros PR 4430 makes every RTOS runner
  take the hook as a weak reference, and the include went with the pin
  bump to 1866c0594f (2b6fe0c).
- The tap images stay on the island's own path: nano-ros refuses
  `net-fvp-tap.toml` (192.168.10.2 on network `tap`) named by the four
  `fvp-tap*` images, "images `fvp-tap` (eth0) and `fvp-tap-stats` (eth0)
  both take 192.168.10.2 on network "tap"", though they are variants of
  one host and never run together. A nano-ros gap (no way to say images
  are alternatives); the island would otherwise need one address per
  variant.

### P7. CAN behind one interface - L

- What: one CAN output interface backed by a board-selected driver; the
  interface name from an image or board fact, not `getenv`. The encoder,
  output mode and frame layout stay the app's. The x5h fault input becomes
  a topic or goes with x5h. The pthread shims and `K_THREAD_STACK` shim go.
- Files: `include/platform/platform_can.h` and its five backends;
  `common/can/control_command_can_output.hpp`;
  `platform/freertos/freertos_threading.h`;
  `platform/freertos/s32z2/pthread.h`.
- Depends on: 4012. Fallback with no nano-ros change: publish ControlMsg
  and let a separate CAN gateway own the bus.
- Done when: no `#if` backend chain, vcan roundtrip CI and the FVP tap
  tunnel pass, all lanes green.

### P8. Census on - M

- What: asi_common has no `PLATFORM_*` left. Add a `linux` image, set
  `entities = "census"`, drop `[census] on_missing = "warn"`, let nano-ros
  derive the pools and, if the census can, `max_parameters`.
- Files: `src/controller_bringup/system.toml`; `asi_common/CMakeLists.txt`
  (platform detection :25-42, `CONFIG_*` mirror :58-81).
- Depends on: P4-P7; 4018 for a derived or loud parameter capacity.
- Done when: `nros build` with the census checks the contract against the
  code on every image, all lanes green.

### P9. Packages and API shape - M

- What: split `autoware_controller_libs` into one ament package per
  upstream package; move the controller to upstream rclcpp spellings
  (`create_subscription`, `create_wall_timer`, `create_publisher`) where
  measured cheap on the R52 lanes; build `can_vcan_sender` as a host
  project; drop the Eigen and `fabsl` workarounds as nano-ros provides them.
- Files: `src/autoware/CMakeLists.txt`; `controller_node.cpp:59-273`;
  `src/controller_pkg/CMakeLists.txt` (:18-23 and :65-70 fallbacks,
  :84-126 sender, :119-121 `_NROS_IN_IMAGE_ADD_EXECUTABLE`);
  `asi_common/CMakeLists.txt` (:51-56 `fabsl`, :158-192 Eigen patch).
- Depends on: 4013 (Eigen), 4016 (host helper opt-out), 4017 (`fabsl`).
  To confirm with a build: whether the controller_pkg fallbacks are still
  needed after nano-ros phase-478 I10.
- Done when: no private nano-ros variable and no board-keyed define in
  ASI CMake, all lanes green.
- Status on nano-ros-next (pending nros12 for `nano-ros`): the `fabsl`
  define is gone (6d3d71e); Eigen is the `eigen` workspace package
  (b8ef477); `can_vcan_sender` is `nano_ros_add_plain_executable` (c35a136,
  4016); the Autoware packages' add-once guard is gone (nano-ros issue
  2756). The controller_pkg fallbacks stay (nano-ros's metadata probe
  adds only the node package). See "Dropped on nano-ros-next".
  - Package split (b39a736): `autoware_controller_libs` is gone;
    `src/autoware/<pkg>/` holds seven ament packages, one per vendored
    upstream package (`autoware_universe_utils`, `_interpolation`,
    `_motion_utils`, `_vehicle_info_utils`, `_trajectory_follower_base`,
    `_mpc_lateral_controller`, `_pid_longitudinal_controller`). Each
    `<depend>`s on what upstream 1.5.0 declares that exists here
    (`autoware_utils*` is `autoware_universe_utils`; rclcpp, tf2,
    diagnostic_*, osqp and the internal message packages are not here),
    plus `nros` and `asi_common`; `autoware_universe_utils` also takes the
    message packages asi_common's umbrella header names. controller_pkg
    `<depend>`s on the six upstream `autoware_trajectory_follower_node`
    names. Each package keeps an `add_subdirectory` fallback for its own
    `<depend>`s. Until pin 1866c0594f each also returned at once when its
    target existed: nano-ros's generated Zephyr root (`west_app.rs`) added
    the image's packages in name order, not `<depend>` order, so
    `autoware_interpolation`'s fallback added `autoware_universe_utils`
    before the root did (without the guard the FVP configure stopped:
    "cannot create target ... already exists"). nano-ros issue 2756 orders
    the Zephyr root as the FreeRTOS one
    (`nano_ros_workspace(ORDER_FROM_DEPENDS)`), and the guard is gone.
  - rclcpp spellings in `controller_node.cpp`, all kept: the control timer
    is `create_wall_timer(period, [this]{...}, &control_group)` in a
    `TimerBase::SharedPtr` member, same named group and same whole-ms
    period, and the base is `rclcpp::Node` (4551531); the nine
    subscriptions are `create_subscription<M>(topic, qos, [this](const M&)
    {...})` (a72efce); the four publishers are `create_publisher<M>(topic)`
    into `Publisher<M>::SharedPtr` members (0934230). A failed create now
    stops the boot at the call instead of latching `ok()` for the entry.
  - text / data / bss (bytes). Each spelling measured alone on the split:

    | build | freertos-an536 | zephyr-fvp | zephyr-s32z |
    |---|---|---|---|
    | before split | 1603576 / 15864 / 35635604 | 2169166 / 33658 / 15475453 | 1985944 / 44056 / 4585363 |
    | split | 1603868 / 15864 / 35635604 | 2169339 / 33658 / 15475453 | 1986236 / 44056 / 4585327 |
    | + timer only | -668 / 0 / -8 | -353 / 0 / -24 | +76 / 0 / +52 |
    | + subscriptions only | -872 / 0 / 0 | -678 / 0 / 0 | -640 / 0 / 0 |
    | + publishers only | +528 / 0 / +32 | +501 / 0 / +32 | +692 / 0 / +76 |
    | all three | 1602300 / 15864 / 35635628 | 2168255 / 33658 / 15475461 | 1985504 / 44056 / 4585355 |

    The split's text delta is the linker keeping another TU's copy of a
    weak Eigen instantiation (`product_evaluator`,
    `dense_assignment_loop`) once the archives link in another order. With
    all three spellings the images are smaller than before the split
    (-1276, -911, -440 text); zephyr-s32z RAM 90.09% of 7 MiB.
  - Run: freertos-posix (`run-freertos-posix-ci.sh`) and freertos-an536
    (`run-freertos-an536-ci.sh`, `nros run` on QEMU) green; zephyr-fvp
    phase 1 boots to "Actuation Safety Island is Live" with the controller
    in DDS_ONLY; zephyr-s32z links. FVP phase 2 (unit_test) stops at
    configure in the P10 test packages, not in these: `nros dev image
    board-facts` for `src/asi_tests/asi_dds_loopback_test --deploy linux`
    finds no system.toml declaring `[image.linux]`.

### P10. Tests and CI on nros run - M

- What: a `test_bringup` package with one image per test program on every
  board; CI via `nros run <image> --expect "Actuation Safety Island is Live"
  --timeout N`; `build.sh` to a thin wrapper or removed; `nros setup` and
  `nros doctor` instead of `bootstrap-asi.sh`; `ament-env.sh` to a doc line.
- Files: `actuation_module/test/zephyr_app/`; `build.sh:486-552`,
  `:683-697`; `.github/scripts/run-freertos-an536-ci.sh`,
  `run-zephyr-fvp-ci.sh`, `run-freertos-posix-ci.sh`;
  `scripts/bootstrap-asi.sh`, `.devcontainer/Dockerfile`,
  `scripts/ament-env.sh`.
- Depends on: `nros run` QEMU and native runners (exist); 4007 for the FVP
  lanes.
- Done when: FreeRTOS lanes run the unit tests too, CI greps no QEMU or FVP
  output by hand, all lanes green.
- Status on nano-ros-next (branch `nros-next-p10`, pin 93368ca929): the
  FreeRTOS POSIX and AN536 lanes are done; the FVP lanes are unchanged
  (`run-zephyr-fvp-ci.sh`, `build.sh` `build_zephyr_test` and
  `test/zephyr_app`). 4007 is fixed at pin 1866c0594f and the controller
  images use it (see "Dropped on nano-ros-next"); the test programs still
  state their FVP parameters in `build_zephyr_test` until they are images.
  - Test images: the unit and DDS loopback tests are one image per board,
    `unit_test_bringup:{freertos-posix,mps3-an536-freertos}` and
    `dds_loopback_test_bringup:{...}` (`src/test_bringup/<program>/`), whose
    entry is the program's own package (`src/asi_tests/asi_<program>`,
    `nano_ros_add_executable(... ROS2_MAIN)` over `test/<program>.cpp`).
    One bringup per program, not one `test_bringup`, and images named after
    their boards: a hand-written entry's configure resolves board facts by
    `NROS_DEPLOY`, which nano-ros sets to the board id, so the image key
    must be the board id. The controller's images are therefore named
    `controller_bringup:<id>` in build.sh and CI (`freertos-posix` is an
    image of three bringups).
  - CI: both lanes build with `nros build controller_bringup:<id>` and run
    every image with `nros run ... --expect <line>... --timeout N`; nothing
    starts QEMU or the POSIX entry, or greps their output, by hand. The test
    images go through `nros_run_program` (ci-helpers.sh): `nros run --plan`
    over the resolved plan with the program's executable added, because
    `nros run` resolves no artifact for a hand-written entry. Local runs
    (2026-11-19): POSIX lane exit 0 (controller, three SI_DDS_INTERFACE
    overrides and the nosuch0 refusal, unit test, loopback, host tests);
    AN536 lane exit 0 (controller on QEMU 12.7 s, unit test 4.1 s, loopback
    6.6 s). A wrong `--expect` line fails the run (exit 1 on timeout).
    CI run 44547138407 (c8e931a): FreeRTOS POSIX green (20 min), FreeRTOS
    AN536 green (21 min); Zephyr FVP red before any build, at the lockstep
    check: `west.yml` still pins 9afb5c8a19 while the submodule is
    93368ca929 (5b600fe moved only the submodule), as on `nano-ros-next`.
  - Workarounds, each to drop when nano-ros covers it: `[census] on_missing
    = "warn"` in both test bringups (the owned entry's host census stops in
    board facts, `--deploy linux`); the bringup guards in `controller_pkg`,
    the seven Autoware packages and the test packages (a workspace configure
    adds every package; the controller's component executable does not
    build in another bringup's root); the `--plan` step above.
  - `build.sh`: the FreeRTOS lanes no longer call it. Its FreeRTOS path
    stays for the CARLA image, the S32Z2 link, the vcan sender and the
    demos, which read its `actuation_*_entry` links; the FVP lanes keep
    `build_zephyr_test`. What went is the QEMU command in its comments and
    the "Zephyr-lane only" refusal, now a pointer to the test images.
  - The source CLI path builds the runner packages too
    (`scripts/nros-cli.sh`); `nros run` needs them.
  - Seen on the AN536 controller (an image this branch does not change):
    "parameter services
    could not be created for node /controller at service
    describe_parameters: Transport(Backend("rmw_ret error"))" after "is
    Live". The POSIX image creates them. Fixed at pin 011a9c4c5b (nano-ros
    issue 2755, see "Pin on nano-ros-next").
  - Not started: `nros setup` / `nros doctor` for `bootstrap-asi.sh`,
    `ament-env.sh` to a doc line.

### P11. Pins and boards - M-L, parallel with P4-P10

- What: one nano-ros pin; west imports the board's
  `west-downstream.yml`; the zephyr submodule or the west project goes;
  the S32Z270 Zephyr board moves upstream; the RTD variant of
  s32z270-freertos; the Zephyr patches and the trace marker come from
  nano-ros; FVP model parameters from the runner.
- Files: `.gitmodules`; `actuation_module/west.yml`;
  `run-zephyr-fvp-ci.sh:48-106` (`assert_pin_lockstep`);
  `build.sh:315-323`, `:386`, `:411-431`;
  `src/s32z270_zephyr_board/`; `src/s32z2_board_glue/`,
  `scripts/provision-nxp-freertos.sh`; `patches/zephyr/`,
  `scripts/apply-zephyr-patches.sh`;
  `asi_common/include/common/diag/trace_marker.hpp`.
- Depends on: 4006, 4007, 4008, 4009, 4014, 4015. To confirm with a
  build: whether a workspace board package is found without
  `NROS_EXTRA_BOARD_PATH` (nano-ros PR 3709 should cover it); file only if
  it reproduces.
- Done when: one pin, no carried Zephyr patch, no consumer-owned board
  package, `build.sh` exports no `NROS_*` or `ARMFVP_*` variable.
- Status on nano-ros-next (pending nros12 for `nano-ros`): the S32Z270
  Zephyr board moved upstream; `src/s32z270_zephyr_board/`,
  `-DBOARD_REVISION=D` and the `NROS_EXTRA_BOARD_PATH` export are gone
  (a3e3df1). The RTD variant exists upstream but is not used yet; see
  "Dropped on nano-ros-next".

### P12. The released nano-ros CLI by default - S

- What: the island uses nano-ros as a released product. The default build,
  CI and the runbook run the prebuilt CLI of the release
  `actuation_module/nros-toolchain.toml` pins (`version = "0.6.0-nros11"`),
  installed the way the nano-ros book pins one
  (`book/src/guide/build/install-options.md`, "Pinning a version"). Building
  the CLI from `modules/nros` is opt-in, for nano-ros changes no release has
  yet.
- Files: `scripts/nros-cli.sh` (new, `nros_cli_select`);
  `actuation_module/nros-toolchain.toml` (new); `build.sh`;
  `.github/scripts/ci-helpers.sh`, `run-freertos-posix-ci.sh`,
  `run-freertos-an536-ci.sh`, `run-zephyr-fvp-ci.sh`;
  `.github/workflows/release.yml`; `scripts/bootstrap-asi.sh`;
  `actuation_module/west.yml`, `modules/nros`; `actuation_module/nros-sdk.lock`.
- Status: done (2026-11-16).
  - Default: `nros_cli_select` runs `$NROS_HOME/sdk/nros/<version>/bin/nros`
    (default `~/.nros`) and its `nros-launch-resolve`, installing the release
    with its own `install.sh --version <version>` when it is missing. The
    release's binary runs, not the launcher, so no dispatch is involved. No
    staleness gate applies: the binary is the release's.
  - Opt-in: `./build.sh --dev-cli ...` or `NROS_DEV_CLI=1` (build.sh, CI
    scripts, `bootstrap-asi.sh`) builds the CLI and the launch resolver from
    `modules/nros`. Only this path sets `NROS_SKIP_STALE_CHECK`, and only on
    a checkout with no edits (nested submodule pointers ignored).
  - `modules/nros` and `west.yml` pin 09219edc75, the commit tag
    `nros-0.6.0-nros11` names (LOCKSTEP kept). On the release path a Zephyr
    image takes the release's own module (`nros build` names
    `share/nano-ros` in `ZEPHYR_EXTRA_MODULES`), while the FreeRTOS images'
    CMake road reads `NROS_REPO_DIR=modules/nros`; `nros_cli_select`
    refuses a checkout that is not the pinned release's tag commit, so the
    two are the same sources. Moving to a new release is three edits
    together: the pin file's `version`, the submodule and `west.yml`.
  - The release's Cyclone DDS is a checkout source in its own tree:
    `build.sh` runs `nros setup --source cyclonedds-src` before a Zephyr
    build on the release path, and `nros setup <board> --rmw cyclonedds`
    (the FreeRTOS kernel, lwIP and Cyclone DDS sources, from the SDK store)
    before an an536 or s32z2 one (idempotent); the posix images use the
    host's Cyclone DDS.
  - `build.sh` states `-D_NANO_ROS_CODEGEN_TOOL=<cli>` on every configure: a
    build directory configured with the other CLI otherwise keeps it from
    its CMake cache (the in-tree CLI, then refused as stale).
  - `nros setup` runs from `actuation_module/` with the release's own index
    (with `--dev-cli`, `modules/nros/nros-sdk-index.toml`), so
    `nros-sdk.lock` records the FreeRTOS kernel source too; that entry is
    committed. The `[system.*]` rows a build appends are the host's ROS
    package versions and stay uncommitted.
  - nros11 already re-resolves the model when a `<param from>` file changes,
    so P3's "delete the model after editing `config/`" note went.
  - Checks: the posix lane passes on the release CLI (149 declared, 145
    seeded, the 4 arrays on their C++ defaults, store 164). `zephyr-s32z`
    links on it: text / data / bss 1954456 / 43972 / 4556655 (P3 at
    5b9e8844a4: 2109592 / 43984 / 4556643). nros11's 34 commits past
    5b9e8844a4 needed no island change beyond this step (the island creates
    no rclc node, the one break they carry).
- The nros12 work, on branch `nano-ros-next` (source CLI, chosen
  automatically): the main pin e845661f0b; the steer-rate arrays in `lateral/mpc.param.yaml`
  (nano-ros PR 4034); dropping the `has_parameter("control_output")` boot
  check (PRs 4030, 4044) and the ListParameters 64-name note (PR 4043); P4
  on `RCLCPP_*_THROTTLE` (PR 4042). It lands when nros12 ships, with the pin
  moved to that release.

## Findings to decide

- `ego_nearest_dist_threshold` and `ego_nearest_yaw_threshold` are 0.0 on
  every image: no translation unit ever gave them a default, and no launch
  value seeded them, so the MPC and PID nearest-index search runs with 0 m /
  0 rad soft limits. Upstream's `common.param.yaml` has 3.0 and 1.046. P3
  kept 0.0 (`config/trajectory_follower_node.param.yaml`) so as not to change
  behaviour; changing them is a controller decision to measure on CARLA.

## To confirm: results (2026-11-16, nano-ros 5b9e8844a4)

- `NROS_EXTRA_BOARD_PATH` after nano-ros PR 3709: still needed. Without it
  `build.sh --platform zephyr-s32z` stops in the west configure at
  `cmake/NanoRosBoardFacts.cmake:227`: `nros dev image board-facts` "no board
  descriptor claims `s32z270-rtu0-zephyr` (deploy `s32z`)". `nros build s32z
  --dry-run` resolves the same board from the workspace; only the
  configure-time board-facts verb misses it (reproduced without a build:
  `nros dev image board-facts src/controller_bringup --deploy s32z`).
  Reported; waiting on nano-ros.
- controller_pkg CMake fallbacks after phase-478 I10: the
  `add_subdirectory` fallbacks (:18-23) are still needed. Without them the
  metadata probe, which configures controller_pkg alone, fails
  (`autoware/trajectory_follower_base/control_horizon.hpp: No such file`)
  and the FVP configure then refuses ("entity inventory was composed after
  this configure's readers ran"). The `if(TARGET app)` re-link (:65-70) is
  not needed: the FVP image builds and links without it (the entry inherits
  the include dirs through the component). It goes with P9.
- FVP board conf: the SMSC MDIO bus and the eth/mdio/phy 80/81/82 order with
  `CHECK_INIT_PRIORITIES=n` are already the nano-ros board's, with the same
  values (dropped from `prj-fvp.conf` in P2). The rest of `prj-fvp.conf`
  still differs from the board and stays: `HEAP_MEM_POOL_SIZE` 4194304 (board
  196608), `MAIN_STACK_SIZE` 524288 (board: per image), `MAX_PTHREAD_MUTEX_COUNT`
  1024 (board 64), `MAX_PTHREAD_COND_COUNT` 512 (16),
  `SYSTEM_WORKQUEUE_STACK_SIZE` 8192 (4096), `NET_BUF_RX/TX_COUNT` 128 (64),
  `NET_PKT_RX/TX_COUNT` 64 (32). Those are the measured island needs to file
  with P6.

## What stays in the island

- The vendored Autoware controllers (MPC lateral, PID longitudinal, utils).
- Supervision: `supervision.hpp`, `supervision_latch.hpp`,
  `input_staleness_gate.hpp`, `candidate_identity.hpp`, `vp_reference.hpp`,
  `startup_config.hpp`, and their host tests.
- The CAN encoder, output mode and frame layout, `can_udp_tunnel.hpp`'s
  datagram format, `demo/can_tunnel_bridge`, `demo/can_carla_bridge`.
- `visionpilot_msgs`, `safety_island_msgs`, `nros-codegen.toml` bounds.
- The bringup: `[[component]]`, `[tasks.control]` and its raw per-RTOS
  priorities, image ids, `[[model]]`, the launch file and the contract.
- The asi_common Zephyr module for the app's own Kconfig symbols
  (`ENABLE_*`, `ASI_TRACE_RING*`, `ASI_THREAD_STATS*`, CAN transport).
- RT-evaluation tooling (trace ring backend, thread stats, CTF and trace
  parsers, an536 gdb probes) until 4009 gives a portable marker path.
- Deployment: `demo/`, `integration/carla/`, the domain split with
  domain_bridge, `check-bridge-contract.py`, `scripts/sntp-server.py`
  while SNTP is the epoch source.
- Host unit tests in `test/host`.

## Links

- Phase 14: [phase-14-nano-ros-conventions.md](phase-14-nano-ros-conventions.md)
- nano-ros issues: https://github.com/NEWSLabNTU/nano-ros/issues/4005 to
  https://github.com/NEWSLabNTU/nano-ros/issues/4018
- nano-ros tracker issues 0758, 0772, 2165: `docs/issues/` in nano-ros
- nano-ros book: `book/src/reference/system-toml.md`,
  `book/src/reference/rclcpp-compatibility.md`, `book/src/guide/port/port-a-cpp-node.md`,
  `book/src/guide/platforms/zephyr.md`, `book/src/reference/cli.md`
