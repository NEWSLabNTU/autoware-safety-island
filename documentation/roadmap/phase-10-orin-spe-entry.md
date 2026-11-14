# Phase 10 — an Orin SPE entry

Status: **planned** (2026-09-04), W1 landed. This phase adds a fifth target to
the workspace — NVIDIA Jetson AGX Orin's Sensor Processing Engine — and it is
the first one whose vendor RTOS ships as source that we stage rather than as a
submodule or an SDK install. W1 is done: `scripts/provision-orin-spe-bsp.sh`
fetches, verifies and stages the BSP, and builds NVIDIA's stock firmware as a
size baseline. Everything after that is planning.

Upstream half: nano-ros
[phase-418](../../modules/nros/docs/roadmap/phase-418-orin-safety-island-and-spe.md),
filed from the same survey. Read that one for what nano-ros must grow; this doc
is what ASI does with it.

## The correction this phase starts from

The original framing was "run the island on Orin's safety island". That is not
available:

- **The Functional Safety Island is not enabled on Jetson.** NVIDIA: "Jetson AGX
  Orin commercial modules are not enabled with functional safety elements.
  Functional Safety will be offered on NVIDIA IGX platform." The FSI's 4× DCLS
  Cortex-R52 cluster is on the die and fused out of reach on this SKU.
- **Even on DRIVE AGX Orin, nobody deploys application code to the FSI.** Its
  firmware is NVIDIA-signed, loaded by MB2, and the published integration
  surface is messaging only — `NvFsiCom`, a carveout plus mailbox against an
  AUTOSAR CDD. A safety application there lives in a guest VM or on an external
  MCU on the FSI's dedicated SPI.
- **The SPE is the Orin core that does accept our code**, on the devkit we
  already have. It is a Cortex-R5 in the always-on domain: it boots before the
  CCPLEX, runs independently of Linux, and survives a Linux crash. That
  independence — not an ASIL claim — is the property this workload wants from a
  safety island, and it is the one the SPE actually has.

So: no ISO 26262 claim comes out of this phase. What comes out is a controller
running on a core that Linux cannot take down, exchanging control commands with
Autoware across an IVC mailbox instead of a network.

## What the vendor BSP actually is (surveyed 2026-09-04, L4T 36.4.4)

Everything below is read out of the staged tree, not from the developer guide.

**Where it comes from.** NVIDIA publishes no standalone SPE download. The BSP is
a 2.6 MB tarball nested inside the 216 MB Jetson Linux public sources archive at
`Linux_for_Tegra/source/spe-freertos-bsp.tbz2` (sha1 `6b5b29c7…`, shipped with
its own `.sha1sum`). Neither the download page nor the SPE Developer Guide says
so. `scripts/provision-orin-spe-bsp.sh` encodes the path and both digests.

**What is in it.** Three trees: `FreeRTOSV10.4.3/` (the kernel, unmodified
upstream v10.4.3), `fsp/` (NVIDIA's Firmware Support Package — peripheral
drivers plus an OS abstraction layer, `osa/`, with backends for FreeRTOS v10,
LittleKernel and SafeRTOS v8/v9), and `rt-aux-cpu-demo-fsp/` (the demo
application, drivers, SoC glue and the build system).

**How it is built.** `make -C rt-aux-cpu-demo-fsp bin_t23x` with
`SPE_FREERTOS_BSP` and `CROSS_COMPILE` set; the toolchain is
arm-gnu-toolchain 13.2.rel1 for `arm-none-eabi`, which NVIDIA does not
redistribute (ARM publishes both x86_64 and aarch64 hosts, so an Orin can build
its own SPE firmware). Output is `out/t23x/spe.elf` and `spe.bin`. **No static
library is produced** — this matters, see the gaps below.

**Compiler and ABI.**

```
-mcpu=cortex-r5 -mthumb-interwork -mfloat-abi=softfp -mfpu=vfpv3-d16
```

Link is `-nostartfiles -e_stext --gc-sections … -lc` against the toolchain's
newlib. Note `softfp`: floating-point *instructions* are available, but the
*calling convention* passes floats in core registers. Rust's
`armv7r-none-eabihf` is hard-float ABI and therefore incompatible; the
compatible pairing is `armv7r-none-eabi` with the FPU turned on as a target
feature. nano-ros currently names the `eabihf` triple for this target, which is
the wrong half of that pair.

**The memory map, which is the whole story.**

```
MEMORY { btcm : ORIGIN = RUN_ADDR, LENGTH = NV_ADDRESS_MAP_AON_BTCM_SIZE }
```

`RUN_ADDR` is `0x0c480000` and `NV_ADDRESS_MAP_AON_BTCM_SIZE` is `0x40000` —
**256 KB, and that single region holds text, rodata, data, bss, the heap and all
five ARM mode stacks.** The image is loaded at `0x70000000` in DRAM and
relocated into BTCM at boot (`relocate-dma.S`). The FreeRTOS config is equally
small: `configMINIMAL_STACK_SIZE` 128 words, 32 priorities, a 1 kHz tick, and
`configCPU_CLOCK_HZ` declared as 1 MHz.

There is no second region in the stock link script. Whether an AST window onto a
DRAM carveout can host code or bulk data is the single highest-value open
question in this phase, because the answer decides whether a middleware fits at
all.

**The baseline, built 2026-09-04 on this Orin** (`--build`, every optional app
left at its shipped `ENABLE_* := 0`):

```
   text    data     bss     dec     hex
 132580    3380    6072  142032   22ad0   spe.elf     (spe.bin: 135964 bytes)
```

**142 KB of the 256 KB is gone before any of our code exists** — that is
FreeRTOS, the FSP, the UART/clock/PM glue and the IVC echo task, with GPIO, I2C,
SPI, GTE, AODMIC and GPCDMA all switched off. Roughly 120 KB is left, and the
heap and five mode stacks come out of it too. Any plan for this target has to
start from that number rather than from a middleware's usual footprint.

One trap worth knowing before the first build: the vendor Makefile takes
`FREERTOS_DIR` from the environment when it is set (`?=`), and an activated ASI
or nano-ros shell exports one pointing at a Cortex-M kernel tree. The build then
fails on a missing `FreeRTOS.h` several frames from the cause. The script passes
it explicitly on the make command line, which outranks the environment.

**IVC, in the numbers the firmware actually uses** (`soc/t23x/include/ivc-config.h`,
`platform/ivc-channel-ids.c`):

| Knob | Value |
|---|---|
| CCPLEX channels declared | 1 (`IVC_NUM_CCPLEX_CHS`) |
| Echo channel id | 1 |
| Frames per direction | 16 |
| Frame size | 64 B (`TEGRA_IVC_ALIGN`) |
| Carveout base | `0x80000000` |
| TX / RX header offsets | `0x100` / `0x10100` |
| Doorbell | HSP `top1`, notify word `0x0000AABB`, ready `0x2AAA5555` |

The SPE-side API is `tegra_ivc_{channel_notified,channel_is_synchronized,
rx_get_read_available,rx_get_read_frame,rx_notify_buffers_consumed,
tx_get_write_space,tx_get_write_buffer,tx_send_buffers}` — which is **exactly
the set nano-ros's `nvidia-ivc` crate already declares** in
`src/fsp.rs`. Phase 100 got the ABI right from the documentation; this survey
confirms it against the source.

**No CAN.** The SPE feature list names CAN, and the AON cluster has controllers,
but the published FSP ships no CAN driver (`fsp/source/drivers/` has no CAN
entry, and `app/` has no CAN app). ASI's vehicle-side CAN cannot move to the SPE
on vendor code alone.

**The Linux side is one sysfs node.** The only stock userspace entry point is
`/sys/devices/platform/bus@0/bus@0:aon_echo/data_channel`, and it echoes.
Adding a real channel means editing
`tegra234-p3737-0000+p3701-xxxx-nv-common.dtsi`, rebuilding the DTB, reflashing,
and owning a kernel-side driver for the new channel.

## Gaps between that and what we have

1. **256 KB, all-in.** ASI on Zephyr/FreeRTOS today carries a controller plus a
   middleware. The MPC lateral + PID longitudinal controllers alone use `sin`,
   `atan2` and matrix work out of newlib and Eigen. Nothing about the current
   image is 256 KB-shaped. This is a sizing exercise before it is a porting one.
2. **nano-ros expects `tegra_aon_fsp.a`.** `nvidia-ivc`'s `fsp` backend links a
   static library named by `NV_SPE_FSP_DIR`. The BSP builds no such archive — it
   compiles objects straight into `spe.elf`. Either the board build compiles the
   FSP sources itself, or the provisioning step produces an archive. That is a
   nano-ros-side decision (phase-418 W6) and it is currently mis-specified.
2b. **The BSP is not licence-gated, and nano-ros says it is.** `nvidia-ivc`'s
   README and manifest describe the FSP as "closed-source", shipping "under SDK
   Manager EULA", such that "anyone without an Orin DevKit account cannot build
   the `fsp` backend". None of that holds: the BSP is source, 117 of its files
   carry the BSD 3-Clause notice, the bundled FreeRTOS is MIT, there is no EULA
   file in the tree, and the download needs no account. The consequence is
   material — the `fsp` backend *can* be built in CI from a scripted download,
   so the mock backend does not have to be the only thing that ever compiles.
3. **The float ABI is wrong upstream.** `armv7r-none-eabihf` versus the BSP's
   `softfp` (phase-418 W3).
4. **No CCPLEX-side channel or bridge.** Nothing in either repo talks IVC from
   Linux; `nvidia-ivc`'s `unix-mock` is a socketpair standing in for one.
5. **Flashing is a reflash of `spe_t234.bin`**, root and recovery mode, so the
   edit-build-run loop is nothing like the FVP or QEMU lanes. Expect the
   an536-style emulated lane to stay the fast loop and hardware to be a gate.

## Work items

- [x] **W1 — provisioning script.** `scripts/provision-orin-spe-bsp.sh`: fetch
      the public sources, verify the pinned sha256, extract and verify the
      nested BSP, stage it under `build/orin-spe/` (never edited in place),
      optionally fetch the matching arm-none-eabi toolchain and build the stock
      demo as a baseline. No sudo; flashing stays manual and documented.

- [ ] **W2 — baseline on hardware.** Build the stock demo, flash
      `spe_t234.bin` on the AGX Orin devkit, and drive the echo channel from
      Linux. **Acceptance:** `echo tegra > …/aon_echo/data_channel` round-trips.
      This is the first thing that proves the loop, and it involves none of our
      code.

- [ ] **W3 — size study, before any port.** The vendor floor is measured
      (142 KB of 256 KB, above). Measure what an ASI controller + nano-ros image
      would add against the ~120 KB that remains: the controller alone, the
      controller plus the nano-ros executor, and the middleware. Establish from
      the FSP whether an AST window can host code or heap in a DRAM carveout.
      **Acceptance:** a table in this doc and a go/no-go on the middleware.
      A no-go is a real outcome — it points at a raw-IVC control channel with
      no middleware on the SPE side, which is a smaller and possibly better
      island.

- [ ] **W4 — the channel.** Add a non-echo IVC channel: `ivc-config.h` and
      `platform/ivc-channel-ids.c` on the SPE side, the DTSI entry plus a
      kernel-side owner on the CCPLEX side. **Acceptance:** a userspace process
      on Jetson Linux exchanges framed messages with an SPE task, matching the
      framing nano-ros's `nvidia_ivc_mock_wire_format` test pins (64-byte
      frames, `u16 total_len` + `u16 offset` header, ≤60 payload bytes).

- [ ] **W5 — `spe_entry` package.** A fifth entry beside
      `freertos_{posix,an536,s32z2}_entry`, same shape:
      `nano_ros_add_executable(actuation_spe_entry BOARD orin-spe LANG cpp
      BRINGUP …/controller_bringup LAUNCH default TYPED DEPLOY orin-spe)`, plus
      a `[deploy.orin-spe]` block in `controller_bringup/system.toml`. Blocked
      on nano-ros restoring `nros-board-orin-spe` (phase-418 W6).

- [ ] **W6 — decide where CAN lives.** The FSP has no CAN driver. Either write
      one against the TRM, or keep the vehicle CAN interface on the CCPLEX and
      let the SPE speak only IVC. **Acceptance:** a decision recorded here with
      its reason; this changes what the island is responsible for.

- [ ] **W7 — bridge daemon.** The CCPLEX side that turns IVC frames into ROS 2
      traffic. nano-ros phase-418 W8 asks the same question from the other side
      — one implementation, and this phase should not grow a second.

## Open questions

- Can the SPE execute from, or heap into, a DRAM carveout through an AST window?
  Everything about the scope of this phase depends on the answer.
- Does zenoh-pico's IVC link fit in what is left of 256 KB after FreeRTOS, the
  FSP and a controller? If not, is a bare framed-command protocol over IVC the
  honest answer for this target?
- `configCPU_CLOCK_HZ` is declared as 1 MHz against a core documented at up to
  200 MHz. Which one is real matters for any timing budget carried over from
  phase 9.
- SafeRTOS OSA backends ship in the FSP. Irrelevant today, but it is the only
  hint in this tree of a certified path.

## References

- `scripts/provision-orin-spe-bsp.sh` — staging, digests and the exact download.
- [Jetson SPE Developer Guide, R36.4](https://docs.nvidia.com/jetson/archives/r36.4/spe/index.html)
- [SPE IVC](https://docs.nvidia.com/jetson/archives/r36.4.3/spe/md__home_jenkins_workspace_Utilities_rt_aux_cpu_demo_fsp_docs_work_rt_aux_cpu_demo_fsp_doc_ivc.html)
- [Cortex-R52 and Cortex-R5 cores in Jetson AGX Orin](https://forums.developer.nvidia.com/t/cortex-r52-and-cortex-r5-cores-in-jetson-agx-orin/239914) — the "not enabled on commercial modules" statement.
- nano-ros `docs/roadmap/phase-418-orin-safety-island-and-spe.md`
- nano-ros `packages/drivers/ipc/nvidia-ivc/` and `packages/rmw/zenoh/zpico-link-ivc/`
