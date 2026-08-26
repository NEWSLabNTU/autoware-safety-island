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
  link-complete but has never scheduled a task. Expect the usual unknowns:
  MPU/PMSAv8 region setup, cache enable ordering, AArch32 boot state, vector
  table placement. This is the same risk the bench session would face — paying
  it in an emulator, where a debugger is free, is the point.
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

Rough, and the middle item carries the variance: bundle skeleton ~1 day;
GICv3 + tick ~1–2 days; startup/netif ~1 day; fixture/CI ~0.5 day; ASI lane
~0.5 day; bring-up debugging 1–3 days. **Call it 5–8 working days**, ~80 % of
it upstream in nano-ros.

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
