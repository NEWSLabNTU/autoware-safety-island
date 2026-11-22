..
 # Copyright (c) 2021-2026, Arm Limited.
 #
 # SPDX-License-Identifier: Apache-2.0

########
Testing
########

The repository ships standalone test programs that share the same build system
as the main application. Each one replaces the controller with a small driver
that exercises one subsystem in isolation.

Pass at most one of the flags below; if more than one is passed, only the
last takes effect.

The unit and DDS loopback tests are images, run with ``nros run`` (below).
``zephyr-fvp`` and ``zephyr-s32z`` support the other test flags.
``freertos-posix`` supports the CAN output test. ``freertos-s32z2`` does not
support test build flags.

**********************************
Unit test (node + DDS round-trip)
**********************************

.. code-block:: console

  $ cd actuation_module
  $ nros run unit_test_bringup:fvp-aemv8r-smp --expect "=== All Tests Passed ===" --timeout 200

Runs ``actuation_module/test/unit_test.cpp`` as an image of its own
(``src/test_bringup/unit_test``) on every board that runs it: the FVP
(``fvp-aemv8r-smp``), the FreeRTOS POSIX simulator (``freertos-posix``) and
QEMU's ``mps3-an536-freertos``. ``nros run`` builds the image when it is
stale and passes once the line has appeared. The test creates a DDS
publisher and subscriber on the same topic, drives a node timer, and checks
that messages arrive and callbacks fire as expected. Useful as a smoke test
after changes to ``include/common/node/`` or ``include/common/dds/``.

**********************
DDS publisher only
**********************

.. code-block:: console

  $ ./build.sh --dds-publisher

Builds ``actuation_module/test/dds_pub.cpp``. The firmware creates a DDS
writer and publishes sample messages in a loop. Pair with a DDS subscriber
on another machine (for example ``ddsperf``) to validate discovery and
network path.

**********************
DDS subscriber only
**********************

.. code-block:: console

  $ ./build.sh --dds-subscriber

Builds ``actuation_module/test/dds_sub.cpp``. The firmware creates a DDS
reader and logs every message it receives. Pair with an external publisher
to validate the inbound path.

**********
CAN output
**********

.. code-block:: console

  $ ./build.sh --can-output-test

Builds ``actuation_module/test/can_output_test.cpp``. The test validates the
control-command encoder and the output modes on the Zephyr FVP. The
``freertos-posix`` controller image sends through nano-ros's SocketCAN backend
on its ``[image.<id>.can] device`` (``vcan0``). See ``demo/can_carla_bridge/README.md``.

SocketCAN ``vcan`` roundtrip (``CAP_NET_ADMIN``, or unprivileged user
namespaces):

.. code-block:: console

  $ ./build.sh --platform freertos-posix --can-output-test -d build/freertos-posix-can
  $ ./actuation_module/test/run-vcan-roundtrip.sh

On ``freertos-posix``, ``--can-output-test`` builds the controller image and,
beside it, ``can_vcan_sender`` (the SocketCAN backend). The C++ sender emits
one classic batch and one CAN-FD frame; the Python decoder receives and
checks both. Without ``CAP_NET_ADMIN`` over ``vcan0`` the script re-runs in a
private network namespace (``unshare -rn``) with a ``vcan0`` of its own; it
exits 77 if neither is available.
``.github/scripts/run-freertos-vcan-ci.sh`` runs the build and both vcan
roundtrips; no GitHub Actions job runs it on this branch.

Python decoder golden vectors and UDP tunnel pack/unpack (no ``vcan``,
no ``python-can``, no CARLA):

.. code-block:: console

  $ python3 demo/can_carla_bridge/test_decoder.py
  $ python3 demo/can_carla_bridge/test_bridge.py
  $ python3 demo/can_tunnel_bridge/test_datagram.py

The closed-loop deployment contract check runs in Open AD Kit PR #146:

.. code-block:: console

  $ python3 deployments/safety-island-carla-simulation/test_contract.py

UDP gateway → ``vcan0`` (needs ``CAP_NET_ADMIN``):

.. code-block:: console

  $ ./actuation_module/test/run-udp-tunnel-roundtrip.sh

Zephyr FVP TAP UDP tunnel (needs ``tun`` and FVP):

.. code-block:: console

  $ ./build.sh --platform zephyr-fvp --network tap --can-output-test \
      -d build/zephyr-fvp-tap-can
  $ ./actuation_module/test/run-fvp-tap-tunnel.sh build/zephyr-fvp-tap-can

On the tap network ``--can-output-test`` builds the test program with
``CAN_ONLY`` over the UDP tunnel. The script uses a ``tap0`` already
configured on the host (owned by the user, ``192.168.10.1/24``, up), creates
one with ``CAP_NET_ADMIN``, or otherwise runs in a private network namespace
(``unshare -rn``) with its own ``tap0`` and ``vcan0``. The namespace needs no
host setup and is the safe choice on a host whose LAN is already
``192.168.10.0/24``.

Native FVP ``--can-output-test`` without ``--network tap`` stays on
``zephyr,can-loopback``.

************
DDS loopback
************

.. code-block:: console

  $ cd actuation_module
  $ nros run dds_loopback_test_bringup:fvp-aemv8r-smp --expect "DDS loopback test passed" --timeout 200

Runs ``actuation_module/test/dds_loopback_test.cpp`` as an image of its own
(``src/test_bringup/dds_loopback_test``), on the same boards as the unit
test. ``./build.sh --dds-loopback-test`` still builds it as a Zephyr test
program, for the real-time evaluation's ``--trace-stats`` / ``--trace``
builds.

**********************
Running tests
**********************

Zephyr test binaries are produced at
``build/<platform>/zephyr/zephyr.elf`` (``zephyr-fvp`` or ``zephyr-s32z``,
or the directory passed with ``-d``) and are deployed in exactly the same
way as the main application:

- AVH: upload via ``./avh.py`` — see :doc:`avh`.
- S32Z: flash via ``west flash`` — see :doc:`s32z_board`.
- Local FVP: boot the ELF with a locally installed Arm FVP simulator.

The test programs above are Zephyr programs. ``freertos-posix`` takes only
``--can-output-test``, which adds the host ``can_vcan_sender`` beside the
controller image:

.. code-block:: console

  $ ./build.sh --platform freertos-posix --can-output-test -d build/freertos-posix-can
  $ ./actuation_module/test/run-vcan-roundtrip.sh build/freertos-posix-can/can_vcan_sender

Clean between builds if switching flags:

.. code-block:: console

  $ ./build.sh -c
