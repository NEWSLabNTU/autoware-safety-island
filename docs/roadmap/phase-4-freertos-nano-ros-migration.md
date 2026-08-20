# Phase 4 — FreeRTOS targets onto nano-ros (retire the vendored CycloneDDS)

Status (2026-08-20): OPEN — planned. The Zephyr targets are fully on
nano-ros (phase-3, validated end-to-end incl. the tap demo); the two
FreeRTOS targets still build the LEGACY vendored `cyclonedds/` submodule
plus the raw `common/dds` + bespoke-Node path. This phase migrates them and
deletes the last owned middleware from the repo. Upstream half:
nano-ros phase-370 (freertos-posix board variant + first live
Cyclone-on-FreeRTOS cell), filed from this scoping.

## Findings that shaped the plan (survey 2026-08-20, pin eace28852)

- nano-ros `nros-platform-freertos` exists (FreeRTOS clock/threads/malloc,
  lwIP-only net with a stubbed multicast join, Cyclone compat shims); the
  Cyclone fork carries a real ddsrt freertos+lwip port and the FreeRTOS
  cmake lane self-provisions `WITH_FREERTOS+WITH_LWIP` — but NO cyclonedds
  cell has ever run pub/sub e2e (zenoh is the only live FreeRTOS backend
  upstream; the old cyclone fixtures were retired in nano-ros Phase 220.C).
- nano-ros phase-292 W4.a already scoped OUR posix-sim case and approved
  "go, small": a board-level variant (`nros-board-freertos-posix`), RMW =
  the existing host/posix Cyclone path verbatim → zero new RMW work.
- Nearest precedent for "RTOS threads + host Cyclone" is threadx-linux —
  currently broken upstream (nano-ros issue 0715, SEGV in
  `_tx_thread_timeout`). Expect that defect class here.
- S32Z2: the Zephyr S32Z board crate exists upstream, but NO FreeRTOS
  S32Z bundle, no Cortex-R52 FreeRTOS toolchain file, no NETC netif in
  nano-ros. Expensive; hardware-gated.

## W5.a — `freertos-posix` (first)

Consumes nano-ros phase-370 W1–W3 (board variant + fixtures). ASI side:

- [ ] Bump the nano-ros pin once phase-370's board variant lands
      (submodule + west.yml lockstep, as in phase-3 W6).
- [ ] `build.sh --platform freertos-posix` switches to the nano-ros verbs:
      `nano_ros_use_board(freertos-posix)` shape, entry baked from the
      same `controller_bringup` model as the Zephyr targets (one bringup,
      two platforms — the point of workspace mode).
- [ ] Retire `build_cyclonedds_host` / `build_cyclonedds_target_posix`,
      the `actuation_module/freertos/` CMake glue that links the vendored
      fork, and the legacy `common/dds/dds.hpp` + bespoke `Node` for this
      target. `freertos_main.cpp` (`-Dmain=actuation_main`) is superseded
      by the generated entry + the board's scheduler glue.
- [ ] Keep the CAN tests middleware-independent (existing rule); re-run
      the FreeRTOS POSIX smoke; walls filed upstream per the
      reference-consumer contract.
- [ ] Delete the vendored `cyclonedds/` submodule when nothing references
      it (S32Z2 still does until W5.b — deletion lands there).

Acceptance: `./build.sh --platform freertos-posix` builds with no vendored
cyclonedds involvement; controller smoke passes on the simulator; the
legacy DDS wrapper is gone from the FreeRTOS-POSIX path.

## W5.b — `freertos-s32z2` (after; hardware-gated)

Blocked on: nano-ros phase-370 W4 (embedded Cyclone proving cell on QEMU
MPS2 — ddsrt-lwip, multicast/IGMP, heap budget) proving the embedded lane,
then an upstream S32Z FreeRTOS board bundle (Cortex-R52 toolchain file,
NETC→lwIP netif from NXP RTD, RTU memory map — the 7 MiB CRAM lesson from
the Zephyr side applies: Cyclone does not fit ~1 MiB).

- [ ] Upstream: `nros-board-s32z270-freertos` bundle scoped and filed
      (successor phase in nano-ros; not part of 370).
- [ ] ASI: replace `freertos_s32z2/scripts/build-cdds-target.sh` + the
      hand toolchain with the board-bundle consumption; NETC glue moves
      behind the board crate where generic, stays in ASI where
      NXP-RTD-licensed.
- [ ] Retire the vendored `cyclonedds/` submodule and its
      `freertos-s32z2` fork branch for good.

Acceptance: S32Z2 image builds via nano-ros; on-target smoke on the
board; `cyclonedds/` gone from `.gitmodules`.

## Non-goals

- New RMW backends on FreeRTOS (cyclonedds only — it is what the Autoware
  side speaks).
- Zephyr-side changes (done in phase-3).
