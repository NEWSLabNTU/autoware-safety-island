# Spikes

Throwaway-by-intent programs kept because the FACT they established is
expensive to re-derive.

## `an536-boot-smoke.S` — QEMU `mps3-an536` Cortex-R52 boot smoke

Phase-6 M0. Answers "can we build and boot an R52 image on this machine, and
where does the console come out", which the phase-6 roadmap then builds on.

```console
$ GCC=~/.nros/sdk/arm-none-eabi-gcc/13.2-nros1/bin/arm-none-eabi-gcc
$ $GCC -mcpu=cortex-r52 -marm -nostdlib -nostartfiles \
    -T demo/spikes/an536-boot-smoke.ld -o /tmp/an536.elf \
    demo/spikes/an536-boot-smoke.S
$ qemu-system-arm -M mps3-an536 -display none -serial stdio -kernel /tmp/an536.elf
AN536-R52-BOOT-OK
```

What it established:

- `-kernel <elf>` loads at the ELF's own addresses and starts at `e_entry`;
  linking at DDR `0x20000000` is sufficient (no bootloader stub).
- The CPU resets into **`hyp32` (EL2)**, so a PL1 RTOS port needs an EL2→EL1
  drop in board startup.
- The console is the **per-CPU UART at `0xe7c00000`** (QEMU `serial0`). The
  four shared CMSDK UARTs at `0xe0205000`–`0xe0208000` are serial1..4 and are
  silent by default — writing only there looks exactly like a dead image.
- It writes to every real UART base in turn with a BOUNDED transmit-full wait.
  The bound matters: an earlier version polled a non-UART address
  (`0xe0202000` is the FPGAIO) and spun there forever, which also looks like a
  dead image.
