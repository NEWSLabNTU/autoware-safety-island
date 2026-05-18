.. Copyright (c) 2026, Arm Limited.
.. SPDX-License-Identifier: Apache-2.0

##########################
nano-ros Migration Roadmap
##########################

Goal
====

Adopt nano-ros as the ROS communication layer while keeping the existing
Autoware Safety Island application logic in C++. The MPC lateral controller,
PID longitudinal controller, CAN output path, and platform interfaces should
remain in their current language. nano-ros may be patched where its generated
C++ bindings, Zephyr module, or middleware backends do not yet cover this use
case.

Current Shape
=============

Autoware Safety Island currently builds Cyclone DDS host tools, generates C
types from local ``actuation_module/src/autoware/autoware_msgs/msg/*.idl``
files with ``idlc``, and wraps Cyclone DDS directly through
``include/common/dds``. ``Node`` owns parameters, timers, subscriptions,
publishers, and a polling loop. Controller logic depends on those wrappers and
on the generated Cyclone C structs.

nano-ros provides Rust, C, and freestanding C++14 client APIs, Zephyr module
integration, CMake code generation via ``nros_generate_interfaces()``, and
multiple RMW backends. Its Zephyr examples already exercise C++ pub/sub on
AEMv8-R, but the Zephyr DDS path is currently documented around the in-tree
DDS backend; Cyclone-on-Zephyr glue is still a likely patch point.

Key Gaps
========

* Interface format: ASI owns ``.idl`` files; nano-ros codegen expects
  ``.msg``, ``.srv``, or ``.action`` inputs for C/C++ bindings.
* Type compatibility: ASI controller code uses Cyclone-generated C structs and
  a custom ``TrajectoryMsg`` wrapper with ``std::vector``. nano-ros generated
  C++ types use fixed-capacity containers.
* Middleware choice: direct Cyclone DDS is the current ASI runtime contract.
  nano-ros supports Zephyr DDS examples, but Cyclone DDS as a nano-ros Zephyr
  backend must be verified or added.
* API shape: ASI uses ``Node::create_subscription(topic, descriptor, cb, arg)``
  and ``Publisher<T>::publish``. nano-ros C++ uses typed generated bindings and
  ``nros::Node``/``nros::Publisher`` handles.
* Zephyr build integration: ASI has a custom top-level ``build.sh`` and local
  Zephyr application. nano-ros expects to be added as a Zephyr module and
  enabled through ``CONFIG_NROS``.
* Runtime configuration: ASI uses ``CONFIG_DDS_DOMAIN_ID`` and raw Cyclone
  config. nano-ros uses ``nros::init(locator, domain_id)`` plus backend Kconfig.
* Tests: existing tests cover unit DDS round-trip and standalone publisher /
  subscriber. Equivalent nano-ros smoke tests must prove ROS 2 interop and
  controller command output.

Roadmap
=======

Phase 0: Branch and Workspaces
------------------------------

Use the ASI ``nano-ros`` branch tracking ``newslab/nano-ros``. Keep the dirty
reference checkout at ``~/repos/nano-ros`` read-only. Use the clean checkout at
``~/repos/nano-ros-autoware`` for nano-ros patches.

Phase 1: Build-System Spike
---------------------------

Add nano-ros as a Zephyr module in ASI without replacing controller logic.
Enable ``CONFIG_NROS`` and ``CONFIG_NROS_CPP_API`` in a separate build/test
mode. Prove a minimal ``std_msgs/Int32`` publisher builds for
``fvp_baser_aemv8r_smp`` under the existing ``./build.sh`` flow.

Phase 2: Interface Generation
-----------------------------

Choose the least risky interface path:

* Preferred short term: convert the required ASI ``.idl`` files back to ROS 2
  ``.msg`` definitions and generate nano-ros C++ bindings from those.
* Patch nano-ros if needed: add IDL ingestion or a converter path that preserves
  ROS 2 package/type names and bounded sequence capacities.

Required message set starts with trajectory, odometry, steering report,
acceleration, operation mode state, control command, and debug timing.

Phase 3: Compatibility Layer
----------------------------

Replace ``common/dds`` internals with a nano-ros-backed adapter while keeping
the controller-facing ``Node`` API mostly stable. Add type conversion helpers
between generated nano-ros messages and current controller aliases where direct
type replacement would be too invasive.

Phase 4: Controller Integration
-------------------------------

Port subscriptions and publishers in ``controller_node.cpp`` to the adapter.
Keep MPC/PID/CAN code unchanged except for message type adjustments. Preserve
the 150 ms control timer, parameter defaults, output mode behavior, and CAN
fallback semantics.

Phase 5: Middleware Decision
----------------------------

Validate ROS 2 interop on FVP. If direct Cyclone semantics are required, patch
nano-ros to expose a Zephyr Cyclone backend and register generated type support
for ASI messages. If zenoh is acceptable for first integration, use
``rmw_zenoh`` on the host side and document the runtime router requirement.

Phase 6: Test and Demo Closure
------------------------------

Rebuild existing test modes as nano-ros variants. Add a smoke test that plays
the existing rosbag inputs and compares ``/control/trajectory_follower/control_cmd``
against the checked-in expected YAML. Keep CAN output tests independent of the
ROS backend.

First Patch Targets
===================

* ASI: ``build.sh``, ``actuation_module/CMakeLists.txt``,
  ``actuation_module/prj_actuation.conf``, ``actuation_module/west.yml``,
  ``include/common/node/node.hpp``, and ``include/common/dds/*``.
* nano-ros: Zephyr C++ codegen, IDL/msg conversion, generated sequence
  capacity controls, and Cyclone DDS Zephyr backend glue if required.
