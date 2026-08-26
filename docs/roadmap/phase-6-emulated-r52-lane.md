# Phase 6 — an EMULATED Cortex-R52 lane (QEMU `mps3-an536`)

Status: **SCOPED + FVP alternative spiked** (2026-08-26). QEMU `mps3-an536`
is the recommended target; implementation not started.

## Why

Everything left in phase-5 (retire the legacy S32Z2 lane, collapse the
dual-mode gates, drop the `cyclonedds/` submodule) is gated on ONE thing:
proving the nros S32Z2 lane reaches parity. Today that proof requires an
S32Z270 board, because the original project has no S32Z2 simulation of any
kind — `docs/user_guide/freertos_s32z2.rst` calls it "not a local validation
target… a bench-only hardware build", it is absent from public CI, and it is
flashed through the NXP `s32dbg` debugger. nano-ros reached the same
conclusion from its side (issue 0772: "no emulator models the S32Z270 RTU").

So the project's simulation story stops at `freertos-posix` (host) and
`zephyr-fvp` (Arm FVP model). The FreeRTOS **Cortex-R52** half — the half the
S32Z2 lane actually is — has never RUN anywhere. Our own s32z270 lane is
link-complete only.

QEMU's `mps3-an536` machine changes that: it is a dual **Cortex-R52** board,
and it is already installed here (system QEMU 9.0.2 and the nano-ros SDK's
11.0.0 both have it). An emulated R52 lane would carry most of the parity
proof phase-5 waits on, in CI, with no hardware.

## What the machine gives us (verified, not assumed)

Probed with `qemu-system-arm -machine mps3-an536` (`info qtree` / `info mtree`):

| device | detail | relevance |
| --- | --- | --- |
| 2× Cortex-R52 | AArch32 R-profile, PMSAv8 | the CPU the S32Z2 lane targets |
| `lan9118` | MMIO `0xe0300000` | **nano-ros already drives this part** |
| `arm-gicv3` | dist `0xf0000000`, redist `0xf0100000` | interrupt controller for the tick seam |
| `cmsdk-apb-uart` ×5 | `0xe0205000`… | console |
| `cmsdk-apb-dualtimer` | `0xe0101000` | alternative tick source |
| DDR | `0x20000000`–`0xdfffffff` | image + heap |

## What it would prove — and what it would NOT

**Proves** (this is most of what phase-5 is waiting for): ARMv8-R AArch32 code
generation, the FreeRTOS R52 port actually SCHEDULING, GIC + tick, lwIP over a
real (emulated) NIC, CycloneDDS on FreeRTOS/R52, the ASI controller running its
MPC/PID loop, and the whole nros entry/tier/param chain on R52. None of that has
ever executed.

**Does not prove**: the NXP NETC ethernet driver, the S32 Config Tools PBcfg
(pinmux/clocks), the licensed `GCC/ARM_CR52_GIC` port and its Thumb-resume
patch, the S32Z270 memory map and SRAM placement, flash/boot on silicon, and
real-time timing. Those stay bench-only. **An `mps3-an536` lane is a substitute
for "does the R52 stack work end to end", never for "does the S32Z270 work".**

Phase-5 W3/W4 should therefore treat this lane as *sufficient to retire the
legacy lane's SOFTWARE* (it is the only thing keeping a second controller
implementation and the vendored Cyclone alive) while the hardware-specific
survivors listed in phase-5 W3 stay untested until a board exists.

## Exploration findings (2026-08-26) — M0 is already PROVEN

Rather than estimate from the outside, a throwaway ~30-line assembly image was
built with the SDK toolchain and run on the machine. It printed:

```
AN536-R52-BOOT-OK
```

Everything below is measured on that run, and each item is a question that
would otherwise have been answered mid-implementation:

- **Toolchain works as-is.** SDK `arm-none-eabi-gcc` 13.2 with
  `-mcpu=cortex-r52 -marm`; the `armv8r-none-eabihf` Rust target is already
  installed (nano-ros `rust-targets` fix).
- **Boot protocol: `-kernel <elf>`.** QEMU loads the ELF at its own addresses
  and starts at `e_entry`; linking `.text` at DDR `0x20000000` is enough. No
  bootloader, no `-device loader` needed. Verified by monitor: `R15` was
  inside the image immediately after reset.
- **Reset mode is `hyp32` (EL2), not SVC/PL1.** This is the single most
  important find: the FreeRTOS `ARM_CRx_No_GIC` port is a PL1 port (it does
  `CPS #SVC_MODE`, uses IRQ/SVC banked stacks). Board startup MUST drop
  EL2 → EL1 before `vTaskStartScheduler()`. Nothing in the existing s32z270
  bundle does that today.
- **Console is `0xe7c00000`, the PER-CPU UART** — that is QEMU's `serial0`.
  The four shared CMSDK UARTs at `0xe0205000`–`0xe0208000` are serial1..4 and
  print nowhere by default. Writing only to `0xe0205000` produces silence,
  which reads exactly like a dead image; this cost two of the spike's
  iterations and is the kind of fact worth writing down.
- **No GICC (memory-mapped CPU interface) exists** — `info mtree` shows only
  `gicv3_dist` (`0xf0000000`) and `gicv3_redist_region[0]` (`0xf0100000`). So
  the port's `configEOI_ADDRESS` MMIO store cannot be a real EOI.
  **This does not require forking the kernel**: the port never reads IAR at
  all — it calls `vApplicationIRQHandler()` with no argument, so
  acknowledgement is ALREADY the board's job. Point `configEOI_ADDRESS` at a
  scratch RAM word (its trailing `STR` becomes harmless) and do the real
  `ICC_IAR1` / `ICC_EOIR1` in our handler.
- **NIC needs no interrupt path**: the sibling MPS2 board registers its netif
  in poll mode (`nros_board_poll_netif`), and `lan9118-lwip` takes a
  configurable `base_addr`, so an536's `0xe0300000` is a parameter. GICv3 is
  therefore needed for the TICK ALONE.

## Roadmap

Ordered so each milestone is independently verifiable and the risky one is
second, not last.

- **M0 — toolchain + boot + console. DONE** (spike above).
- **M1 — FreeRTOS actually scheduling.** The only substantial new code, and
  the whole risk of the phase: EL2→EL1 drop, per-mode stacks and `VBAR`, MPU
  left disabled initially, GICv3 init (distributor, redistributor, and the
  CPU interface via the A32 `ICC_*` CP15 encodings), generic-timer tick on
  PPI 30, and a `vApplicationIRQHandler` that does IAR → dispatch → EOI with
  `configEOI_ADDRESS` aimed at scratch. *Acceptance: two tasks alternate on
  the console and the tick count advances.* This is also the work the
  eventual S32Z2 bench session needs, with only the GIC base changing.
- **M2 — networking.** lwIP + the existing `lan9118-lwip` at `0xe0300000`,
  poll-mode netif, static IP. *Acceptance: host pings the image over tap.*
- **M3 — a real nano-ros bundle.** `nros-board-mps3-an536-freertos`:
  descriptor, `cargo_config` QEMU runner, entry signature, priority plan,
  CMake overlay, `fixtures.toml` witness row, CI cell. *Acceptance: the
  fixture builds and boots from a clean checkout in CI.*
- **M4 — CycloneDDS. SPLIT, after checking what upstream actually proved.**
  An earlier draft of this doc called M4 "a port, not a bring-up" on the
  strength of nano-ros phase-370 W4. Reading that phase doc closely says
  less than the summary does: the MPS2 cell "builds, boots, and creates
  writers and readers", and its stretch goal — "boots and DELIVERS locally"
  — is not claimed as met. **Cross-node DDS delivery out of a QEMU FreeRTOS
  guest has not been demonstrated upstream.** So:
  - **M4a — entities.** Participant + writers/readers on an536. A genuine
    port of the proven MPS2 state; low risk.
  - **M4b — delivery.** A sample actually reaching a host Cyclone peer. NEW
    ground, and the part ASI needs. Note the existing an385 QEMU cells use
    **slirp** with a TCP zenoh locator; Cyclone's SPDP wants multicast, which
    slirp does not carry — so this milestone owns a networking decision (tap,
    or a Cyclone unicast-peer config), not just a build.
- **M5 — the ASI lane.** `[deploy.an536]`, `src/freertos_an536_entry/`, a
  `build.sh` lane and a CI phase. *Acceptance: controller boot markers plus
  the control loop ticking at its configured period.*
- **M6 — re-scope phase-5.** Retire what the emulated lane proves; leave the
  hardware-specific survivors (NETC, PBcfg, licensed port, flash) listed as
  bench-gated.

## Execution order — nano-ros first, then ASI

Deliberately upstream-first: every milestone below M5 is board/RTOS
infrastructure that belongs in nano-ros, and ASI consumes it through a pin
bump exactly like the s32z270 lane did. Nothing in ASI needs to change until
N6 lands.

### Upstream (nano-ros) — N0…N6

- **N0.** `just phase-new mps3-an536-freertos-board` to reserve the phase
  number (repo rule: never read the highest and add one), then write
  `docs/roadmap/phase-NNN-*.md` there. This ASI doc stays the consumer view.
- **N1 — bundle skeleton.** `packages/boards/nros-board-mps3-an536-freertos/`:
  `nros-board.toml` (names `["mps3-an536-freertos", "an536"]`, platform
  `freertos`, `supported_netstacks = ["lwip"]`, `board_crate`, entry
  signature, capabilities, `[board.cmake] toolchain_file =
  cmake/toolchain/arm-freertos-armcr52.cmake` — **already exists** from
  phase-372 — a `[board.priority_plan]` copied from the family, and a
  `cargo_config` runner `qemu-system-arm -M mps3-an536 -nographic -kernel`);
  `Cargo.toml` / `build.rs` / `src/lib.rs` + its own `Cargo.lock` and the
  root `Cargo.toml` exclude entry (cross-only crate, the phase-372 lesson);
  `config/{FreeRTOSConfig.h,lwipopts.h,arch/cc.h,an536.ld}` with `.text` at
  DDR `0x20000000`. `[arch.cortex-r52]` in
  `config/freertos/nros-platform.toml` is **already there** — reuse, do not
  add.
- **N2 — M1, the risky one.** `c/board_an536.c` + a small `.S`: vector table,
  **EL2→EL1 drop** (the M0 find), per-mode stacks, `VBAR`, MPU off initially,
  GICv3 init (dist `0xf0000000`, redist `0xf0100000`, CPU interface via the
  A32 `ICC_*` CP15 encodings), generic-timer tick on PPI 30, and
  `vApplicationIRQHandler` doing IAR → dispatch → EOI with
  `configEOI_ADDRESS` aimed at a scratch word. Console = `0xe7c00000`.
  Overlay `cmake/board/nano-ros-board-mps3-an536-freertos.cmake` mirroring
  the s32z270 one (env-provisioned `FREERTOS_DIR`/`FREERTOS_PORT`,
  `enable_language(ASM)` + `portASM.S`). *Acceptance: two tasks alternate on
  the console, tick count advances.*
- **N3 — M2, networking.** Strong `nros_board_register_netif` /
  `nros_board_poll_netif` over the EXISTING
  `packages/drivers/net/lan9118-lwip` at base `0xe0300000`, static IP.
  *Acceptance: host pings the guest.*
- **N4 — M3, make CI run it.** `examples/fixtures.toml` witness row
  (`platform = "freertos"`, `NANO_ROS_BOARD = "mps3-an536-freertos"`, own
  `build_subdir`), lane membership for `just build-test-fixtures`, and a
  runtime cell in the test matrix. *Acceptance: builds and boots from a
  clean checkout in CI.*
- **N5 — M4a, Cyclone entities.** *Acceptance: participant + writers/readers,
  matching the MPS2 cell's proven state.*
- **N6 — M4b, Cyclone delivery.** The networking decision above (tap, or
  unicast peers). *Acceptance: a sample crosses from the QEMU guest to a host
  peer.* **This is the gate ASI's closed loop depends on** — everything ASI
  needs except this is already available at N4.

### Consumer (ASI) — A1…A6

- **A1.** Pin bump to the nano-ros commit carrying the bundle (submodule +
  `west.yml` lockstep), then the usual three-lane sweep.
- **A2.** `[deploy.an536]` in `src/controller_bringup/system.toml` — the same
  bringup both other lanes already bake from.
- **A3.** `src/freertos_an536_entry/` (`nano_ros_add_executable`, `BOARD
  mps3-an536-freertos`, `LANG cpp`, `TYPED`, `BRINGUP ../controller_bringup`,
  `LAUNCH default`, `DEPLOY an536`) + `package.xml`.
- **A4.** `actuation_module/CMakeLists.txt`: today the cross seams are keyed
  on `NANO_ROS_BOARD STREQUAL "s32z270-freertos"` — the toolchain selection
  (line ~23), the per-board `SUBDIRS`, the Eigen psincos patch and the
  pthread shim staging. **Broaden that condition to "any ARMv8-R cross
  board"** rather than duplicating the block; both boards want exactly the
  same remedies. The pthread shim's port switch (`ASI_S32Z2_NXP_PORT`)
  already defaults to the plain `xTaskCreate*`, which is what an536 uses.
- **A5.** `build.sh`: a `freertos-an536` lane mirroring
  `build_freertos_s32z2_nros()` (nros sync, cross toolchain, the same sizing
  knobs; kernel from the nros pin, no NXP provisioning).
- **A6.** A CI phase that boots the image under QEMU and asserts the
  controller markers plus the control-loop period — the same markers the
  posix lane asserts. With N6, extend to a closed loop against the demo
  stack.

## Work breakdown

Most of this belongs UPSTREAM in nano-ros — it is board/RTOS infrastructure,
and the standing rule is that ROS infra lives there while ASI holds production
logic.

**nano-ros — new board bundle `nros-board-mps3-an536-freertos`**
1. Bundle skeleton copied from the two existing siblings: descriptor
   (`nros-board.toml`), `Cargo.toml`/`build.rs`/`src/lib.rs`, `lwipopts.h`,
   `arch/cc.h`, `FreeRTOSConfig.h`, linker script for DDR at `0x20000000`.
   The `nros-board-s32z270-freertos` bundle supplies the ARMv8-R half and
   `nros-board-mps2-an385-freertos` supplies the QEMU-board half — including
   its `cargo_config` runner line, which is how the fixture boots in CI.
2. **The genuinely new piece: GICv3 + tick for R52.** The s32z270 bundle
   already declares the seam (`configSETUP_TICK_INTERRUPT` /
   `configCLEAR_TICK_INTERRUPT` → weak `nros_board_setup_tick_interrupt()` /
   `_clear_`, plus `configEOI_ADDRESS`); on an536 these become REAL: GICv3
   distributor + redistributor + CPU interface (ICC_* sysregs) init, and a
   tick from the ARM generic timer (PPI) or the CMSDK dualtimer. This is the
   only substantial new code, and it is the same shape the S32Z2 bench work
   will need, so it is not throwaway.
3. Board C startup (`c/board_mps3.c`): ARMv8-R vector table, reset into PL1,
   MPU/cache setup, UART console, and the strong netif hooks wired to the
   EXISTING `packages/drivers/net/lan9118-lwip` at base `0xe0300000`.
4. CMake overlay + `[arch.cortex-r52]` reuse (already exists from phase-372),
   a `fixtures.toml` witness row, and a runtime cell so CI boots it.

**ASI — small, mirrors what phase-4 W5.b items 2–4 already did**
5. `[deploy.an536]` row in `controller_bringup/system.toml`, an entry leaf
   `src/freertos_an536_entry/`, a `build.sh` lane, and a CI phase that boots
   the image and asserts the controller markers.

**Reuse inventory (why this is cheaper than it sounds):** the lan9118 lwIP
driver, the Cortex-R52 toolchain file and cflag profile, the FreeRTOS kernel
provisioning, the entry/codegen/tier machinery, the QEMU-fixture pattern, and
the CycloneDDS-on-FreeRTOS work (nano-ros phase-370 W4 already boots a Cyclone
FreeRTOS cell on QEMU MPS2 — an536 changes the CPU, not the stack).

## Risks

- **First-ever running R52 FreeRTOS image in this tree.** The s32z270 lane is
  link-complete but has never scheduled a task. Remaining unknowns after M0:
  MPU/PMSAv8 setup (deferrable — run MPU-off first), cache enable ordering,
  and the EL2→EL1 drop. This is the same risk the bench session would face —
  paying it in an emulator, where a debugger is free, is the point.
- **EL2 reset is a real gap in the EXISTING s32z270 bundle too** (found by the
  M0 spike). Whatever M1 writes for the drop is likely needed there as well;
  worth checking against the NXP boot flow when hardware appears.
- **`GCC/ARM_CRx_No_GIC` is a no-GIC port**: it deliberately leaves interrupt
  controller setup to the consumer, which is exactly item 2. If it proves a bad
  fit, the fallback is a small in-bundle port derived from it, NOT the licensed
  NXP port (which cannot be committed).
- **Dual-core**: run core 0 only; FreeRTOS SMP is out of scope.
- QEMU networking for a closed-loop demo needs tap (user-mode networking will
  not carry DDS multicast) — the demo's `setup-tap.sh` already exists, but the
  bridge/compose wiring assumes the FVP island's address plan.
- **NIC risk is low** (spike finding): the netif is poll-mode on the sibling
  board, so the lan9118 needs no IRQ path, and GICv3 is required for the tick
  alone.

## Effort

Revised after the M0 spike, which removed the boot/toolchain/console unknowns
and answered the EOI question without a kernel fork:

| milestone | estimate |
| --- | --- |
| M0 toolchain + boot + console | **done** (~1 h) |
| M1 EL2→EL1, GICv3, tick, scheduler | 1.5–3 days (all the variance) |
| M2 lwIP + lan9118 | 0.5–1 day (driver exists, poll mode) |
| M3 bundle + fixture + CI | 1 day |
| M4a Cyclone entities | 0.5–1 day (ports the proven MPS2 state) |
| M4b Cyclone DELIVERY out of QEMU | 1–2 days (new ground upstream; owns the tap-vs-unicast decision) |
| M5 ASI lane | 0.5 day |
| M6 phase-5 re-scope | 0.5 day |

**5–9 working days**, ~85 % upstream in nano-ros (N0–N6); ASI's own share is
about a day. The estimate is dominated by two milestones — M1 (EL2/GIC/tick)
and M4b (delivery out of a QEMU guest) — rather than spread across unknowns.
Everything ASI needs to BUILD and BOOT is available after N4; only the closed
loop waits for N6.

## The FVP alternative — SPIKED 2026-08-26, and it does NOT come free

The premise was that `FVP_BaseR_AEMv8R` (already provisioned, already wired
into the tap demo, SNTP and compose) would give the demo integration for free
if it could run an R52-class AArch32 image. Half of that is true and the
load-bearing half is not:

- **AArch32 is fine — better than expected.** `cluster0.has_aarch64` DEFAULTS
  to `0` on this model (our Zephyr lane is what turns it on), the reset
  controls for A32 exist (`RVBAR32`, `TEINIT`,
  `aarch32_reset_from_impdef_addr`), and Zephyr even ships
  `fvp_baser_aemv8r_fvp_aemv8r_aarch32{,_smp}` board variants. The CPU side of
  an FVP FreeRTOS image is not the problem.
- **The NIC kills the "free integration" claim.** The FVP's ethernet is
  `bp.smsc_91c111` — an SMSC/LAN91C111, which Zephyr drives with its own
  `eth_smsc91x.c`. It is NOT the LAN9118 family (the model's
  `not_lan911x` parameter is about failing a LAN911x probe, not about being
  one). nano-ros ships lan9118 drivers only (`lan9118-lwip`,
  `lan9118-smoltcp`) and has no smsc91c111 lwIP driver, so networking on an
  FVP FreeRTOS lane means writing one — a chunk comparable to the GICv3 work,
  and precisely what `mps3-an536` avoids.

**Verdict: QEMU `mps3-an536` is the primary target.** Its `lan9118` is the
part nano-ros already drives, the driver takes a configurable `base_addr` (so
an536's `0xe0300000` is a parameter, not a port), and the existing MPS2 board
registers its netif in POLL mode (`nros_board_poll_netif`) — so the NIC needs
no interrupt wiring, leaving GICv3 needed only for the tick. That is the
cheapest possible shape for the risky part.

The FVP stays a LATER option, worth taking only if the closed-loop tap demo is
wanted on the R52 lane too, and only once someone writes the smsc91c111 lwIP
driver. A non-networked FreeRTOS-on-FVP smoke would work today, but QEMU gives
the same thing for free and in CI.

## Acceptance

1. `nros-board-mps3-an536-freertos` boots on QEMU and runs the FreeRTOS
   scheduler with a working tick (upstream fixture, in CI).
2. lwIP + CycloneDDS come up; the image creates a participant and exchanges a
   topic with a host peer.
3. The ASI controller image boots on the lane and prints its markers, with the
   control loop ticking at its configured period.
4. Phase-5 W3/W4 re-scoped against it: what the emulated lane proves is
   retired; the hardware-specific survivors (NETC, PBcfg, licensed port) stay
   listed as bench-gated.
