#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# nano-ros build knobs for the ZEPHYR lanes, in one place because more than one
# entry point has to resolve them identically.
#
# `build.sh` sources this before configuring. So does the FVP CI script, before
# it starts a model with `west build --target run` -- that command RE-ENTERS
# cmake, and a re-configure without these knobs resolves the crate defaults:
#
#   nros: the executor arena cannot fit in the platform heap.
#     NROS_EXECUTOR_ARENA_SIZE = 458752
#     NROS_ZEPHYR_HEAP_SIZE    = 65536
#
# The build that produced the ELF had them; the reconfigure that ran the ELF
# did not, so the lane failed after a successful build. Sourcing the same file
# in both places is what keeps that from recurring.
#
# Every value stays `${VAR:-default}` so an explicit environment override still
# wins, exactly as when these lived inline.

export NROS_MAX_PARAMETERS="${NROS_MAX_PARAMETERS:-256}"
# Executor sizing (nros-node build.rs): the controller registers 5
# subscriptions + timers + publishers (default MAX_CBS=4 → creation fails
# with TransportError at boot), and /planning trajectories run 9-14 KiB
# (default per-subscription RX buffer is 1 KiB). The arena would derive to
# ~1 MB from MAX_CBS=16 x 16 KiB buffers (action-client worst case); cap
# it at what this image actually needs.
export NROS_EXECUTOR_MAX_CBS="${NROS_EXECUTOR_MAX_CBS:-16}"
export NROS_SUBSCRIPTION_BUFFER_SIZE="${NROS_SUBSCRIPTION_BUFFER_SIZE:-16384}"
export NROS_EXECUTOR_ARENA_SIZE="${NROS_EXECUTOR_ARENA_SIZE:-458752}"
# Zephyr heap for the nros allocator funnel. nano-ros phase-391 W3 moved
# Zephyr allocation onto an rlsf-backed funnel and turned COMMON_LIBC_MALLOC
# OFF, which retires CONFIG_COMMON_LIBC_MALLOC_ARENA_SIZE — the 16 MiB arena
# this image used to get. The funnel's own default is 64 KiB (sized for the
# zenoh examples); Cyclone plus the MPC/PID controller need far more, and
# without this the image hangs at boot on an allocation that never returns,
# with every core parked in WFI.
#
# NECESSARY BUT NOT SUFFICIENT, measured: at pin ea592285e the lane still
# hangs with this set, so something else in that wave also has to be sized or
# configured. Kept because 64 KiB is unarguably wrong for this image and the
# next person to attempt the bump should not have to rediscover the knob.
# Inert at the current pin, which predates the funnel.
export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-8388608}"

# Application heap. nano-ros 60b4e0c1e ("the Zephyr funnel is rlsf-backed")
# moved z_malloc AND __rust_alloc off Zephyr's kernel heap onto an rlsf arena
# in nros-platform, sized by THIS env var (compile-time `option_env!`,
# default 64 KiB).
#
# So `CONFIG_HEAP_MEM_POOL_SIZE` no longer governs application allocation.
# It is still set to 4 MiB in the board conf, still looks authoritative, and
# after that commit controls nothing on this path. Crossing it with the 64
# KiB default hangs the image between "Network interfaces found: 1" and
# "Starting Controller Node", with no fault, no log and no error code —
# found by a 9-step bisect, filed as NEWSLabNTU/nano-ros#41.
#
# 4 MiB matches the figure phase 7 measured for this application; see
# docs/roadmap/phase-7-realtime-evaluation.md W2. Keep the two in step: if
# the heap requirement changes, BOTH this and the board conf's
# CONFIG_HEAP_MEM_POOL_SIZE need looking at, since which one bites depends on
# the nano-ros pin.
#
# This export only reaches cargo because the nano-ros pin now REGISTERS the
# knob (`_nros_resolve_knob` in zephyr/cmake/nros_cargo_build.cmake). Before
# that it was documented in the Rust source and absent from the generated
# cargo command, so exporting it did nothing at all — verified by grepping
# build.ninja, after several wrong diagnoses that each looked plausible.
export NROS_ZEPHYR_HEAP_SIZE="${NROS_ZEPHYR_HEAP_SIZE:-4194304}"
# ...and force cargo to actually honour it. `HEAP_SIZE` is read with
# `option_env!`, which cargo bakes at compile time, but nros-platform has NO
# build.rs and so emits no `cargo:rerun-if-env-changed=NROS_ZEPHYR_HEAP_SIZE`.
# Cargo therefore does NOT invalidate on a change to this variable: an
# already-built rlib is reused with the previous size compiled in, and the
# image hangs exactly as if the variable had never been set.
#
# That is not hypothetical. It is why FVP CI kept failing after this export
# landed: build.sh exported 4194304 (verified by probe), and the ELF still
# carried a 0x10b38 (64 KiB) `zephyr_heap::HEAP` because the rlib was served
# from cache. Standalone builds passed only because they happened to compile
# it fresh.
#
