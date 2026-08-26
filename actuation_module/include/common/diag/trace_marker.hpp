// Copyright (c) 2026, Arm Limited.
// SPDX-License-Identifier: Apache-2.0

#ifndef COMMON__DIAG__TRACE_MARKER_HPP_
#define COMMON__DIAG__TRACE_MARKER_HPP_

// Application markers in the CTF stream (phase-6 W6).
//
// A CTF capture shows thread switches, ISRs and lock activity, but callbacks
// run INSIDE an executor wake as ordinary function calls, so the timeline
// cannot see where one begins or ends. Measuring control-loop latency — as
// opposed to executor cadence — needs the application to say so.
//
// These markers land in the same stream as the scheduling events, so a
// callback's span can be read against the thread switches and interrupts that
// occurred during it. That correlation is the whole point; a printk-based
// stopwatch (PROFILE_POINT in logger.hpp) gives a duration but cannot say what
// preempted the cycle, and its UART write perturbs the very cycle it measures.
//
// Zephyr 3.7 has no user-event facility (upstream's named_event came later), so
// the event is added out-of-tree by
// patches/zephyr/0002-ctf-app-marker-event.patch, which declares `app_marker`
// (id 0x70) in the TSDL and exports the function below. scripts/parse-zephyr-ctf.py
// reads the TSDL directly, so it decodes the new event with no changes.
//
// Cost when tracing is off: nothing at all — the calls compile away.

#include <cstdint>

namespace common::diag
{

/// Marker sites. Keep the values stable: they appear in captured traces, and a
/// renumbering silently reinterprets every trace taken before it.
enum class Marker : uint32_t
{
  control_cycle_enter = 1,  ///< arg: cycle counter, low 32 bits
  control_cycle_exit = 2,   ///< arg: outcome (see CycleOutcome)
};

/// `arg` values for control_cycle_exit — why the cycle ended.
enum class CycleOutcome : uint32_t
{
  commanded = 0,      ///< a control command was computed and published
  safe_stop = 1,      ///< inputs missing or stale; safe stop commanded
  not_ready = 2,      ///< controllers not ready yet
};

#if defined(CONFIG_TRACING_CTF)

extern "C" void sys_trace_app_marker(uint32_t marker_id, uint32_t arg);

inline void trace_marker(Marker marker, uint32_t arg = 0)
{
  sys_trace_app_marker(static_cast<uint32_t>(marker), arg);
}

#else

inline void trace_marker(Marker, uint32_t = 0) {}

#endif  // CONFIG_TRACING_CTF

}  // namespace common::diag

#endif  // COMMON__DIAG__TRACE_MARKER_HPP_
