# Phase 1D - Cyclone-on-Zephyr enablement (upstream patch)

**Goal.** Make `CONFIG_NROS_RMW_CYCLONEDDS=y` work on Zephyr (FVP + S32Z)
inside the nano-ros Zephyr module. POSIX-side Cyclone RMW + stock-RMW
wire-compat already done upstream (nano-ros Phase 117). Remaining work is
**Zephyr Kconfig + module wiring**, plus flipping the FVP example to use
it. **All patches land in `~/repos/nano-ros-autoware` — not ASI.**

**Status.** Draft, not started. **Revised 2026-05-18** — backend choice
is no longer open: Cyclone is in, validated POSIX. ASI doesn't own a
vendored Cyclone anymore (Phase 1.3 deletes it). Scope = nano-ros Zephyr
glue.

**Parallelism.** Can run beside 1B / 1C. ASI side is just a Kconfig flag.

## Upstream state to build on (nano-ros Phase 117 done)

- `nros-rmw-cyclonedds` standalone CMake project at
  `packages/dds/nros-rmw-cyclonedds/` registers an 18-slot
  `nros_rmw_vtable_t` via `nros_rmw_cffi_register`.
- Cyclone DDS submodule pinned to **tag `0.10.5`** at
  `third-party/dds/cyclonedds/` — matches installed
  `ros-humble-cyclonedds` + `rmw-cyclonedds-cpp` 1.3.4 for stock-RMW
  interop.
- POSIX E2E pub/sub interop vs stock `rmw_cyclonedds_cpp` validated
  (117.12).
- vtable mapping (selected slots):
  - `open` → `dds_create_domain_with_rawconfig` + `dds_create_participant`
  - `create_publisher` → `dds_create_topic` (descriptor lookup) +
    `dds_create_writer` + `dds_qset_*`
  - `publish_raw` → `dds_writecdr` (raw CDR blob path)
  - `try_recv_raw` → `dds_take` → memcpy CDR blob
  - `register_*_event` / `assert_publisher_liveliness` → NULL (Phase 108
    deferred)
- Wire-compat conventions frozen — see Phase 1B.
- ASI Zephyr boards exist upstream: `nros-board-fvp-aemv8r-smp`,
  `nros-board-s32z270dc2-r52` (Phase 117.10 / 117.11).
- FVP nros-cpp example exists, wired to flip `CONFIG_NROS_RMW_CYCLONEDDS=y`
  once the symbol lands.
- Driver: `just cyclonedds {setup,build,build-rmw,test,doctor,clean,ci}`.

## Outstanding upstream gap (this phase owns)

- `~/repos/nano-ros-autoware/zephyr/Kconfig` does not yet expose
  `CONFIG_NROS_RMW_CYCLONEDDS`. Today's choices:
  `NROS_RMW_{ZENOH,XRCE,DDS}` (DDS = dust-dds).
- `~/repos/nano-ros-autoware/zephyr/CMakeLists.txt` lacks the Cyclone
  sources block (parallels existing zenoh/xrce blocks).
- Cyclone DDS may need additional platform shims for Zephyr (sockets,
  threads, time, multicast). Audit against
  `nros_platform_zephyr_shims.c` for missing symbols.

## ASI side (Phase 1.3 already deletes vendored Cyclone)

- Once `CONFIG_NROS_RMW_CYCLONEDDS=y` is available upstream, ASI flips its
  spike from `CONFIG_NROS_RMW_DDS=y` (or zenoh) → `CONFIG_NROS_RMW_CYCLONEDDS=y`.
- ASI does **not** maintain its own Cyclone version pin. nano-ros's
  `third-party/dds/cyclonedds/` (0.10.5) is the source of truth.

## Work Items

- [ ] **1D.1 - Confirm interop requirement.**
  First PR targets wire-compat with stock `rmw_cyclonedds_cpp` on ROS 2
  Humble (carry 117.X conventions forward to Zephyr). Document any
  Zephyr-specific deviations.
- [ ] **1D.2 - Add `CONFIG_NROS_RMW_CYCLONEDDS` to nano-ros Zephyr Kconfig.**
  Extend `zephyr/Kconfig` with the Cyclone backend choice (mutually
  exclusive with existing `NROS_RMW_{ZENOH,XRCE,DDS}`). Patch in
  `~/repos/nano-ros-autoware`.
- [ ] **1D.3 - Wire Cyclone build path in nano-ros Zephyr module.**
  Add the matching sources block in `zephyr/CMakeLists.txt` to pull
  Cyclone DDS + the `nros-rmw-cyclonedds` C++ backend into the Zephyr
  build. Mirror existing zenoh-pico block shape (file globs +
  `zephyr_compile_definitions` + include dirs).
- [ ] **1D.4 - Cover platform-shim gaps.**
  Audit what Cyclone needs that `nros-platform-zephyr` doesn't yet
  provide. Likely areas: socket option compat, multicast join semantics,
  scheduler interactions, `clock_gettime` mapping. Extend
  `nros_platform_zephyr_shims.c` as needed.
- [ ] **1D.5 - Flip FVP example Kconfig.**
  Enable `CONFIG_NROS_RMW_CYCLONEDDS=y` in
  `examples/zephyr/cpp/dds/talker/prj.conf` (FVP variant). Build + boot
  on FVP. Observe published topic from host `ros2 topic echo` with
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`.
- [ ] **1D.6 - Build for S32Z.**
  Same backend variant for `s32z270dc2_rtu0_r52@D`. ELF parity bar
  first; runtime if hardware available.
- [ ] **1D.7 - Validate QoS semantics.**
  Compare ASI's reliability/history needs vs the Cyclone RMW vtable QoS
  surface. Fail entity creation if a required QoS policy is unsupported.
  Default service QoS: reliable + transient_local + keep_last(10).
- [ ] **1D.8 - Switch ASI smoke to Cyclone backend.**
  Once 1D.5 lands, ASI flips its spike from
  `CONFIG_NROS_RMW_DDS=y` (or zenoh) to
  `CONFIG_NROS_RMW_CYCLONEDDS=y`. Update docs.
- [ ] **1D.9 - Keep zenoh as documented fallback.**
  Optional: keep a `CONFIG_NROS_RMW_ZENOH=y` build variant for hostless
  bring-up scenarios. Document the router + locator if retained.

## Acceptance Criteria

- [ ] `CONFIG_NROS_RMW_CYCLONEDDS=y` builds for `fvp_baser_aemv8r_smp`
      and `s32z270dc2_rtu0_r52@D` (ELF parity).
- [ ] FVP binary publishes a test topic observed by stock
      `ros2 topic echo` (Humble + `rmw_cyclonedds_cpp`).
- [ ] Domain ID / locator / backend choice visible in build logs + docs.
- [ ] ASI consumes nano-ros's bundled Cyclone — no ASI-side vendor pin.
- [ ] Unsupported QoS or missing router/agent fails clearly.
- [ ] Patches live in `~/repos/nano-ros-autoware` with focused commits;
      ASI repo carries no nano-ros source diffs.

## Likely Files

- `~/repos/nano-ros-autoware/zephyr/Kconfig`
- `~/repos/nano-ros-autoware/zephyr/CMakeLists.txt`
- `~/repos/nano-ros-autoware/zephyr/nros_platform_zephyr_shims.c`
- `~/repos/nano-ros-autoware/zephyr/module.yml`
- `~/repos/nano-ros-autoware/packages/dds/nros-rmw-cyclonedds/*`
- `~/repos/nano-ros-autoware/packages/boards/nros-board-fvp-aemv8r-smp/*`
- `~/repos/nano-ros-autoware/packages/boards/nros-board-s32z270dc2-r52/*`
- `~/repos/nano-ros-autoware/examples/zephyr/cpp/dds/talker/prj.conf` (Kconfig flip)
- `actuation_module/prj_actuation.conf` (ASI smoke flip; downstream)
