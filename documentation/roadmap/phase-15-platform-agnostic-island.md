# Phase 15 - a platform-agnostic island on nano-ros

Status: in progress (2026-11-16). P1, P2 done; P3 done with interim
workarounds waiting on nano-ros. nano-ros pinned at main ea94566e87.
nano-ros gaps filed as issues 4005-4018.

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
| 4005 | consumer evidence for tracker issues 0758 (SNTP re-acquire, epoch failure policy), 0772 (FreeRTOS epoch), 2165 (Zephyr SMP log stops after four records) | P4, P5 |
| 4006 | `nros-toolchain.toml` cannot pin a git commit | P11 |
| 4007 | fvp runner: model parameters (SMSC NIC, tap hostbridge, uart out_file) | P10, P11 |
| 4008 | carry the Zephyr CTF app_marker and k_thread_priority_set patches | P11 |
| 4009 | public trace marker through the installed trace sink | P11 |
| 4010 | `RCLCPP_*_THROTTLE` (steady clock) and `RCLCPP_*_ONCE`; fixed at the pin (PR 4042) | P4 |
| 4011 | board network file for Zephyr images (`NET_CONFIG_*`) | P6 |
| 4012 | board-owned CAN frame driver | P7 |
| 4013 | SDK Eigen 3.4 for arm-none-eabi | P9 |
| 4014 | Zephyr board descriptor for S32Z270 RTU0 (`s32z2xxdc2@D`) | P11 |
| 4015 | s32z270-freertos RTD variant (GIC port, NETC netif) | P11 |
| 4016 | public opt-out for a host helper executable in a board build | P9 |
| 4017 | fvp-aemv8r-smp newlib lacks `fabsl` | P9 |
| 4018 | bug: `declare_parameter` past the store capacity silently returns the default; fixed at the pin (PR 4030: the boot stops) | P3, P8 |

Related, not ours: 3761 (CAN FD E2E profile and a FlexCAN helper).

## Pin

nano-ros main ea94566e87 (2026-11-16), 65 commits past 5b9e8844a4: a
declaration with no store slot stops the boot (PR 4030, issue 2634), a launch
list parameter seeds as a typed array (PR 4034, 2638), `RCLCPP_*_THROTTLE` on
the clock argument plus `_ONCE` / `_SKIPFIRST` (PR 4042, 2636),
`list_parameters` past 64 names with rclcpp's prefix and depth filtering
(PR 4043, 2639), and a metadata probe store of 1024 (PR 4044, 2640). The
launch resolver is rebuilt with it (`just setup-launch-resolve`). Every
param file and launch value was re-checked for the coming type-mismatch
refusal: every double is a float literal, every integer an integer.

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
- Status: done (2026-11-16); three sub-items wait on nano-ros.
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
    declared parameter no file seeds, a seeded one nobody declares, a param
    file value of another type than the declaration (so the coming 4018 fix,
    which refuses a mistyped launch value, is safe to pin), and an image whose
    `max_parameters` is below the declared count (164 >= 149 on all 13).
  - Boot check: `has_parameter("control_output")` (the last declared) must
    hold, else "Safety Island parameters incomplete"; the posix, an536 and
    FVP CI lanes forbid that line. It logs, not exits: the metadata probe runs
    the constructor with a store smaller than 149 and must finish.
  - Waiting on nano-ros, interim in place:
    - the C++ `declare_parameter()` defaults stay (same values as the files):
      the per-component metadata probe constructs the node with no launch
      values and a small store, so a node declaring without defaults cannot
      be probed. Goes with P8's census or a probe that seeds the image.
    - the four steer-rate-limit arrays stay C++ defaults: a YAML list reaches
      the store as one comma-joined string (type string, not double_array).
      The checker exempts arrays and refuses one that is seeded.
    - `ros2 param list` shows 64 of the 149 (the ListParameters reply caps at
      64 names), so the readback below reads by name.
    - a param-file edit alone does not re-resolve the model (its
      `meta.inputs` omit `<param from>` files): locally, delete
      `build/nros/models/controller_bringup/system_model*.yaml` after editing
      `config/`. CI builds fresh.
  - Checks: on the posix image, all 149 parameters read back by name
    (`~/get_parameters`) have the same type and value as on the pre-P3 image
    (`ros2 param list` would show 64). The resolved models give the
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
