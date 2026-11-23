// Copyright (c) 2026, Arm Limited.
// SPDX-License-Identifier: Apache-2.0

#ifndef COMMON__DIAG__TRACE_MARKER_HPP_
#define COMMON__DIAG__TRACE_MARKER_HPP_

// Application markers in the CTF stream (phase-7 W6).
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
// The markers go through nano-ros's public application trace marker,
// rclcpp::trace_marker (nano-ros issue 2641), on the same sink and clock as
// the executor's callback events (ids 16-27). On Zephyr with
// CONFIG_TRACING_CTF the sched-task entry installs the default sink, which
// writes the CTF `app_marker` event (id 0x70, fields marker_id and arg) that
// nano-ros's Zephyr patch set declares; scripts/parse-zephyr-ctf.py reads the
// TSDL directly, so it decodes the event with no changes. Elsewhere the
// markers reach whatever sink the application installs, if any.
//
// Cost: with nano-ros built without its `trace-callbacks` feature
// (CONFIG_NROS_TRACE_CALLBACKS, on only in the trace images) or with no sink
// installed, the call is an id range check and a branch.

#include <cstdint>

#include <rclcpp/rclcpp.hpp>

namespace common::diag
{

/// Marker sites, the application block 1..15 (rclcpp::kTraceAppMarkerFirst
/// .. kTraceAppMarkerLast). Keep the values stable: they appear in captured traces, and a
/// renumbering silently reinterprets every trace taken before it.
enum class Marker : uint32_t
{
  control_cycle_enter = 1,  ///< arg: cycle counter, low 32 bits
  control_cycle_exit = 2,   ///< arg: outcome (see CycleOutcome)

  // Phase boundaries INSIDE the cycle (phase-7 W7). The loaded capture showed
  // 10 % of cycles over 336 ms and a 4.6 s worst case, with period tracking
  // duration — so the callback runs long rather than being preempted. These
  // split it at the same points the existing PROFILE_POINT stopwatch uses, so
  // the tail can be attributed to a phase instead of guessed at.
  control_phase_inputs_done = 3,  ///< createInputData + readiness checks done
  control_phase_lateral_done = 4, ///< MPC lateral solve done
  control_phase_longitudinal_done = 5,  ///< PID longitudinal solve done

  // Inside the input phase (phase-7 W9). The loaded capture put input handling
  // at 22.7 ms p50 — three quarters of the 30 ms period on its own, second
  // only to the MPC solve. processData() is flag checks and throttled logging,
  // so the suspect is the member copies in createInputData(), which deep-copy
  // an 8.8 KiB trajectory every cycle. These two split that apart.
  control_phase_data_checked = 6,   ///< processData() returned ready
  control_phase_inputs_copied = 7,  ///< createInputData() copies done
};

/// `arg` values for control_cycle_exit — why the cycle ended.
enum class CycleOutcome : uint32_t
{
  commanded = 0,      ///< a control command was computed and published
  safe_stop = 1,      ///< inputs missing or stale; safe stop commanded
  not_ready = 2,      ///< controllers not ready yet
};

inline void trace_marker(Marker marker, uint32_t arg = 0)
{
  // Every Marker value is an application id (1..15); the result is ignored
  // as the hand-written call's was.
  static_cast<void>(rclcpp::trace_marker(static_cast<uint32_t>(marker), arg));
}

}  // namespace common::diag

#endif  // COMMON__DIAG__TRACE_MARKER_HPP_
