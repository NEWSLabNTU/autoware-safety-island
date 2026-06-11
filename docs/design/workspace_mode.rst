..
 # Copyright (c) 2026, Arm Limited / NEWSLab NTU.
 #
 # SPDX-License-Identifier: Apache-2.0

#########################################
nano-ros Workspace-Mode Migration (design)
#########################################

Design of record for moving ``actuation_module`` from the Phase 1
single-fused-app shape onto nano-ros **workspace mode**. Tracked by
``docs/roadmap/phase-2-workspace-mode-migration.md``. Cross-refs
nano-ros RFC-0024 (workspace layout), RFC-0032 §8a (C++ Entry runtime),
and nano-ros Phases 215 + 236.

Context
=======

Phase 1 landed ASI as a downstream nano-ros consumer: a single Zephyr
binary, one ROS node (``controller``), Cyclone-on-Zephyr runtime via a
hand-written ``common/node`` shim over ``nros::Node`` and an imperative
``main.cpp`` boot. nano-ros is now in bug-fixing mode and cleared for
full adoption.

Workspace mode splits a system into three package roles:

- **Node pkg** — carries the node declaration (the unit of identity).
- **Bringup pkg** — pure-declarative ``system.toml`` + ``launch.xml``
  describing the topology (names, namespaces, topics, remaps, params).
- **Entry pkg** — the binary that boots a topology against a Board
  (``NROS_MAIN`` / ``nano_ros_entry`` cmake).

Decisions
=========

**D1 — ASI adopts workspace mode.** The ``controller`` runtime is lifted
into Node pkg + Bringup pkg + C++ Entry pkg. Rationale: declarative
topology, ``nros check`` identity validation, and a clean path to adding
perception/planning nodes later without imperative ``main.cpp`` surgery.

**D2 — ASI drives nano-ros Phase 215 + Phase 236 to completion.** The C++
Entry path exists (nano-ros Phase 219) but is native-only and
record-only — no live embedded runtime. Rather than build an ASI-local
workaround, ASI is the **reference consumer** that forces:

- Phase 215 — board-crate import (``nano_ros_use_board(fvp-aemv8r-smp)``),
- Phase 236 — embedded (Zephyr) Board adapter + real ``NodeContext``
  runtime,

to land in nano-ros. ASI's working ``common/node`` shim and ``main.cpp``
boot are the **blueprint** for the upstreamed runtime (RFC-0032 §8a), so
this is a lift-and-upstream, not greenfield.

**D3 — the ``common/node`` shim is upstreamed, not deleted.** It becomes
the nano-ros ``NodeContextOps`` runtime (Phase 236.A) + embedded
``Board::run()`` (Phase 236.B). ASI then consumes the upstreamed version
and drops its local copy.

**D4 — single fused binary is retained.** Workspace mode does not imply
multiple processes; ASI stays one Entry pkg = one binary (one process).
Multi-Entry orchestration is out of scope until a real multi-deploy
fleet exists.

Identity mapping
================

The unit of ROS identity is the node, resolved by the planner from the
launch tree + ``system.toml`` at codegen (nano-ros RFC-0024). ASI's
single node maps cleanly; the 8 autoware components are *libraries*, not
nodes, and stay plain CMake libs.

Three identity gaps must close (tracked as Phase 2 items I1–I3):

============  =================================================  ===================================================
Gap           Today                                              Workspace-mode target
============  =================================================  ===================================================
I1 class      ``autoware::motion::control::                      ``class = <pkg-dir>::Controller`` — alias-shim or
              trajectory_follower_node::Controller``;            dir-rename so ``nros check`` passes (decide 2.A.2)
              pkg dir ``autoware_trajectory_follower_node``
I2 node name  ``Node("controller", …)`` baked in C++ ctor        ``system.toml [[component]].name`` / launch
                                                                 ``<node name>``; node reads resolved name
I3 topics     literal strings in ``create_publisher`` /          ``launch.xml`` ``<remap>``; current strings stay
              ``create_subscription``                            as declared defaults (behaviour unchanged)
============  =================================================  ===================================================

Open questions
==============

- **I1 method** — thin ``controller_pkg::Controller`` registration alias
  vs renaming the Node pkg directory. Alias is less churn; rename is
  cleaner long-term. Decide in Phase 2.A.2.
- **Output modes** — ASI's DDS-only / CAN-only / DDS+CAN Kconfig choice
  maps to a launch arg (``$(var control_output)``); confirm the CAN path
  stays outside the ROS-node identity (it is not a topic).
- **Parameter arrays** — the MPC ``std::vector<double>`` weights remain
  in a local map until ``nros::ParameterServer`` grows sequences
  (nano-ros gap, separate phase); workspace mode does not change this.
- **Board granularity / entity storage** — owned by nano-ros Phase 236
  (RFC-0032 §8a open items); ASI inherits whatever lands.
