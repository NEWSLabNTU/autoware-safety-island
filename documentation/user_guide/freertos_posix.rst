..
 # Copyright (c) 2026, Arm Limited.
 #
 # SPDX-License-Identifier: Apache-2.0

###############
FreeRTOS POSIX
###############

The ``freertos-posix`` runtime target runs the safety-island application on a
Linux host using the FreeRTOS POSIX port. It is the FreeRTOS local validation
path: useful for DDS discovery, domain-bridge, controller-loop, and CAN encoder
checks without S32Z2 hardware or NXP SDK inputs.

Use ``freertos-posix`` when you want to validate FreeRTOS behavior locally. Use
``freertos-s32z2`` only for the hardware-specific S32Z2 path.

*************
Prerequisites
*************

- Repository submodules initialized with
  ``git submodule update --init cyclonedds zephyr freertos-kernel``.
- A Linux environment with CMake, a C++17 compiler, Eigen3, and the repository's
  FreeRTOS and CycloneDDS submodules. The development container from
  :doc:`quickstart` is the recommended environment.
- For end-to-end DDS validation with the demo containers, a multicast-capable
  host interface such as ``eth0`` or ``wlp2s0``.

*************
Build
*************

From the repository root:

.. code-block:: console

  $ ./build.sh --platform freertos-posix -d build/freertos-posix

``build.sh`` runs ``nros build freertos-posix``: nano-ros generates the
workspace root and the entry from ``[image.freertos-posix]`` in
``actuation_module/src/controller_bringup/system.toml`` and builds it.

Output (a link to the artifact ``nros build`` reports):

.. code-block:: text

  build/freertos-posix/actuation_posix_entry

The build has no DDS-interface or output-mode option: the image publishes
control on DDS (``DDS_AND_CAN`` on the CAN stub). The DDS interface is
chosen at runtime with ``SI_DDS_INTERFACE``. It takes an interface name, an
IPv4 address, or ``auto`` (let CycloneDDS choose):

.. code-block:: console

  $ SI_DDS_INTERFACE=wlp2s0 ./build/freertos-posix/actuation_posix_entry

Replace ``wlp2s0`` with the interface that should carry domain-2 DDS traffic.

The released ``actuation_freertos`` binary is built with ``lo`` and relies on
this override for LAN use; see :doc:`open_ad_kit`.

*************
Run Locally
*************

Run the built executable from the repository root:

.. code-block:: console

  $ ./build/freertos-posix/actuation_posix_entry

With the default loopback DDS interface this starts the runtime and waits for
input topics on domain 2. It is useful as a smoke test for startup and logging.

***********************
Run With The Demo Stack
***********************

The demo compose override mounts ``demo/cyclonedds.posix.xml`` and pins domain
2 to ``SAFETY_ISLAND_DDS_INTERFACE``. Start the Autoware, bridge, and visualizer
containers from the ``demo/`` directory:

.. code-block:: console

  $ cd demo
  $ SAFETY_ISLAND_DDS_INTERFACE=wlp2s0 \
      docker compose -f docker-compose.yaml -f docker-compose.posix.yaml up -d

Return to the repository root, then build and run the runtime using the same
interface:

.. code-block:: console

  $ cd ..
  $ ./build.sh --platform freertos-posix -d build/freertos-posix
  $ SI_DDS_INTERFACE=wlp2s0 ./build/freertos-posix/actuation_posix_entry

Verify bridged control commands from the ``demo/`` directory:

.. code-block:: console

  $ cd demo
  $ docker compose -f docker-compose.yaml -f docker-compose.posix.yaml exec safety-island-bridge bash -lc \
      'source /opt/ros/humble/setup.bash && source /opt/autoware/setup.bash && ROS_DOMAIN_ID=1 ros2 topic echo --once /control/trajectory_follower/control_cmd'

If discovery stalls, check that ``SAFETY_ISLAND_DDS_INTERFACE`` and
``SI_DDS_INTERFACE`` name the same multicast-capable host interface. See
:doc:`troubleshooting`.

``scripts/run-posix-demo.sh`` does all of the above in one command, from the
repository root, in a shell with ROS 2 sourced (the binary loads CycloneDDS's
libraries from it). With ``--drive`` it also drives a mission:

.. code-block:: console

  $ SAFETY_ISLAND_DDS_INTERFACE=lo scripts/run-posix-demo.sh --drive
  $ scripts/run-posix-demo.sh --down

The mission spawns the ego on a lane derived from the map
(``demo/derive-drive-goals.py``), sets a route about 30 m along it through
``/api/routing/set_route_points``, engages, and waits for the route state
``ARRIVED``. It passes when the ego moved and prints "DRIVING MISSION OK".
Without ``--drive`` the script seeds a fixed pose that is off the lane
Autoware 2.0.0 plans, so the island stays in its emergency stop; it only checks
that control commands stream back.

Closed-loop Autoware planning against CARLA is :doc:`can_carla_closed_loop`.

*************
Test Builds
*************

``freertos-posix`` supports the unit, DDS publisher, DDS subscriber, and CAN
output test flags documented in :doc:`testing`. It does not support the Zephyr
DDS loopback test.
