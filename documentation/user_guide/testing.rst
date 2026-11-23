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
stale and passes once the line has appeared. A Zephyr image builds against
this checkout's west workspace (``west init -l actuation_module`` and
``west update`` at the repository root): ``nros`` finds it from
``actuation_module`` with no flag. The test creates a DDS
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

  $ cd actuation_module
  $ nros run can_output_test_bringup:fvp-aemv8r-smp --expect "CAN output tests passed" \
      --forbid "ZEPHYR FATAL ERROR" --timeout 200

Runs ``actuation_module/test/can_output_test.cpp`` as an image of its own
(``src/test_bringup/can_output_test``) on the FVP. The test validates the
control-command encoder and the output modes, then sends a command through
nano-ros's CAN frame driver over ``zephyr,can-loopback`` and reads the frames
back. ``./build.sh --can-output-test`` still builds it as a Zephyr test
program (``test/zephyr_app``), for the tap network's UDP tunnel below. The
``freertos-posix`` controller image sends through nano-ros's SocketCAN backend
on its ``[image.<id>.can] device`` (``vcan0``). See ``demo/can_carla_bridge/README.md``.

Network tests with no password
==============================

The vcan roundtrip and the FVP tap tunnel need a ``vcan0`` and a ``tap0``
they can configure (``CAP_NET_ADMIN`` over them). ``scripts/run-in-netns.sh``
gives a test a network namespace of its own: it starts a throwaway container
with ``docker run --rm --cap-add NET_ADMIN --device /dev/net/tun --network
none`` (an Ubuntu 22.04 helper image, ``scripts/netns/Dockerfile``, built on
first use), creates the devices inside it and runs the test there, as the
calling user unless ``--root``. It needs no sudo and no password, only a
docker the user can run (the ``docker`` group). The host's interfaces are
never touched, a host ``vcan0`` included; there is no ``--privileged`` and no
host network. The host kernel needs the ``vcan`` module (loaded on demand)
and ``/dev/net/tun``.

SocketCAN ``vcan`` roundtrip (phase-15 P7):

.. code-block:: console

  $ .github/scripts/run-freertos-vcan-ci.sh

or by hand:

.. code-block:: console

  $ ./build.sh --platform freertos-posix --can-output-test -d build/freertos-posix-can
  $ scripts/run-in-netns.sh --vcan --root -- \
      actuation_module/test/run-vcan-roundtrip.sh build/freertos-posix-can/can_vcan_sender
  $ scripts/run-in-netns.sh --vcan --root -- \
      actuation_module/test/run-udp-tunnel-roundtrip.sh

On ``freertos-posix``, ``--can-output-test`` builds the controller image and,
beside it, ``can_vcan_sender``: the island's encoder through nano-ros's
SocketCAN backend of ``<nros/platform_can.h>``. The sender emits one classic
batch and one CAN-FD frame on ``vcan0``; the Python decoder receives and
checks both; then, with ``vcan0`` at the classic MTU, CAN-FD init must fail
closed. ``--root`` because that check changes ``vcan0``'s MTU. The UDP
roundtrip sends a tunnelled batch to the host gateway
(``demo/can_tunnel_bridge/gateway.py``), which puts it on ``vcan0`` for the
decoder. Run outside a namespace, the scripts still fall back to
``unshare -rn`` and exit 77 when neither works. CI runs both in the
FreeRTOS POSIX job, whose container has ``NET_ADMIN`` (``ASI_NETNS_DIRECT=1``:
the job container is the namespace).

Python decoder golden vectors and UDP tunnel pack/unpack (no ``vcan``,
no ``python-can``, no CARLA):

.. code-block:: console

  $ python3 demo/can_carla_bridge/test_decoder.py
  $ python3 demo/can_carla_bridge/test_bridge.py
  $ python3 demo/can_tunnel_bridge/test_datagram.py

The closed-loop deployment contract check runs in Open AD Kit PR #146:

.. code-block:: console

  $ python3 deployments/safety-island-carla-simulation/test_contract.py

Zephyr FVP TAP UDP tunnel (phase-15 P10; needs the FVP):

.. code-block:: console

  $ export ARMFVP_BIN_PATH=~/.nros/sdk/arm-fvp/11.31.28/bin
  $ .github/scripts/run-zephyr-fvp-tap-ci.sh

or by hand:

.. code-block:: console

  $ ./build.sh --platform zephyr-fvp --network tap --can-output-test \
      -d build/zephyr-fvp-tap-can
  $ scripts/run-in-netns.sh --vcan --tap -- \
      actuation_module/test/run-fvp-tap-tunnel.sh build/zephyr-fvp-tap-can

On the tap network ``--can-output-test`` builds the test program with
``CAN_ONLY`` over the UDP tunnel. ``--tap`` makes ``tap0`` (owned by the
calling user, ``192.168.10.1/24``, up) in the container; the model opens it
as that user, its frames reach the gateway on ``192.168.10.1:5555`` and land
on the container's ``vcan0``, where the decoder must accept a command and the
console must say ``CAN output tests passed``. The model starts from the
build dir's recorded command (``build.sh --run``), so the container needs
neither west nor cmake; ``ARMFVP_BIN_PATH``'s install is mounted read-only.
The namespace is also the safe choice on a host whose LAN is already
``192.168.10.0/24``. Outside a namespace the script still uses a ``tap0``
already configured on the host, or ``unshare -rn``. CI runs it in the Zephyr
FVP job, whose container has ``NET_ADMIN`` and ``/dev/net/tun``.

The FVP tap demo with the Autoware compose stack (``scripts/run-tap-demo.sh``)
is not a test and still wants a host ``tap0`` (``sudo
scripts/setup-tap.sh``): its compose stack reaches the island over that host
interface.

Native FVP ``--can-output-test`` without ``--network tap`` stays on
``zephyr,can-loopback``, as the image does.

************
DDS loopback
************

.. code-block:: console

  $ cd actuation_module
  $ nros run dds_loopback_test_bringup:fvp-aemv8r-smp --expect "DDS loopback test passed" --timeout 200

Runs ``actuation_module/test/dds_loopback_test.cpp`` as an image of its own
(``src/test_bringup/dds_loopback_test``), on the same boards as the unit
test. ``dds_loopback_test_bringup:fvp-aemv8r-smp-stats`` adds the thread
runtime statistics; the FVP lane runs it with ``--settle`` so the console
holds the whole thread-analyzer report for its stack check.
``./build.sh --dds-loopback-test`` still builds it as a Zephyr test program,
for the real-time evaluation's ``--trace`` builds.

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
  $ scripts/run-in-netns.sh --vcan --root -- \
      actuation_module/test/run-vcan-roundtrip.sh build/freertos-posix-can/can_vcan_sender

Clean between builds if switching flags:

.. code-block:: console

  $ ./build.sh -c
