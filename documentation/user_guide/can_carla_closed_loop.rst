..
 # Copyright (c) 2026, Arm Limited.
 #
 # SPDX-License-Identifier: Apache-2.0

########################################
Closed-loop CAN and CARLA
########################################

Drive a CARLA ego from Safety Island control over classic CAN while Autoware
plans against the simulator. Design: :doc:`../design/can_carla_integration`.

This is a **host demo**. GitHub Actions never starts CARLA or Open AD Kit.

.. note::

   Not runnable on the nano-ros branch yet. The demo needs a controller image
   that sends control on CAN only (``CAN_ONLY``). ``build.sh`` lost its
   ``--control-output`` option with the CycloneDDS lanes, and no bringup
   image (``actuation_module/src/controller_bringup/system.toml``) selects
   that mode: ``freertos-posix`` is fixed at ``DDS_AND_CAN`` on the CAN stub
   (no SocketCAN), and ``fvp-tap`` at ``DDS_ONLY``. The CAN path itself is
   tested by the ``--can-output-test`` programs (:doc:`testing`). The steps
   below show where a ``CAN_ONLY`` image goes once one exists.

**********************
Two repositories
**********************

- **Open AD Kit PR #146** ``deployments/safety-island-carla-simulation/``:
  CARLA, domain-bridge, sensors-only ``autoware_carla_interface`` and its
  deployment configuration. Autoware's follower stays running for Auto/Engage
  but does not actuate CARLA.
- **This repository**: ``freertos-posix`` ``CAN_ONLY``, ``vcan0``, and
  ``demo/can_carla_bridge``.

Open AD Kit's deployment and sensors-only overlay are maintained in
`PR #146 <https://github.com/autowarefoundation/openadkit/pull/146>`_.

**********************
Host loop
**********************

GPU host, Docker NVIDIA runtime, and the ``vcan`` kernel module. Open AD Kit
also needs large UDP buffers; see that project's CARLA simulation docs.

1. Start Open AD Kit (no ``--drive``):

   .. code-block:: console

     $ cd /path/to/openadkit
     $ git fetch origin pull/146/head
     $ git checkout FETCH_HEAD
     $ ./openadkit run safety-island-carla-simulation --gpu

   Do not start ``carla-simulation`` first and recreate
   ``carla-interface``. That leaves a second ego in CARLA and breaks NDT.

2. From this repository:

   .. code-block:: console

     $ sudo ip link add vcan0 type vcan
     $ sudo ip link set up vcan0
     $ ./build.sh --platform freertos-posix -d build/freertos-posix
     $ CYCLONEDDS_URI='<General><Interfaces><NetworkInterface name="lo"/></Interfaces></General>' \
         SAFETY_ISLAND_CAN_IFACE=vcan0 ./build/freertos-posix/actuation_posix_entry

   This build sends no CAN on vcan0 (see the note above).
     $ python3 demo/can_carla_bridge/bridge.py --interface vcan0 --ego-role ego_vehicle

3. In RViz: set a goal, engage. ``candump vcan0`` should show ``0x100`` /
   ``0x101`` / ``0x102`` (``0x103`` in CAN-FD mode).

Confirm Autoware is not applying ``VehicleControl`` to the ego. The overlay
skips ``apply_control()``; the CAN bridge applies
``VehicleAckermannControl``. Autoware Auto/Engage is required so SI sees
``AUTONOMOUS``; it does not mean Autoware drives CARLA.

**********************
CAN-FD (optional)
**********************

``freertos-posix`` can send one 24-byte ``0x103`` frame instead of the classic
three. Everything else is unchanged:

.. code-block:: console

  $ SAFETY_ISLAND_CAN_FORMAT=fd SAFETY_ISLAND_CAN_IFACE=vcan0 ./build/freertos-posix/actuation_posix_entry
  $ python3 demo/can_carla_bridge/bridge.py --interface vcan0 --can-format fd --ego-role ego_vehicle

See :doc:`../design/can_fd`.

**********************
DDS
**********************

Open AD Kit pins domain 1 to loopback. Its closed-loop deployment's
``cyclonedds.xml`` pins domains 1 and 2 to ``lo``.
Run the Safety Island with ``lo`` named in ``CYCLONEDDS_URI``, as above. The domain-bridge
forwards the five controller inputs 1 → 2 and does not forward
``control_cmd`` (``CAN_ONLY``). The SI subscribes to ``/planning/trajectory``,
the trajectory Autoware 2.0's own follower reads, so Autoware 2.0 needs no
remap. Another Autoware needs a remap from the topic its follower reads to
``/planning/trajectory`` in the bridge (:doc:`../design/topics`). ``/system/operation_mode/state`` is bridged with
``transient_local`` durability so a late-joining SI still sees
``AUTONOMOUS``.

**********************
Pins
**********************

Open AD Kit's ``deployments/safety-island-carla-simulation/config.env`` pins
CARLA and component images by digest. Record ``git rev-parse HEAD`` in the
Open AD Kit checkout alongside the Safety Island commit when you run the demo
so a later rerun can use the same pair.

**********************
Tests
**********************

Privilege-free (no CARLA):

.. code-block:: console

  $ python3 demo/can_carla_bridge/test_decoder.py
  $ python3 demo/can_carla_bridge/test_bridge.py
  $ python3 demo/can_tunnel_bridge/test_datagram.py

The deployment contract test lives in Open AD Kit:

.. code-block:: console

  $ python3 deployments/safety-island-carla-simulation/test_contract.py

**********************
Zephyr FVP TAP
**********************

Same open-loop and closed-loop host demos, with Safety Island on
``zephyr-fvp --network tap`` instead of ``freertos-posix``. Frames still
land on ``vcan0``. Native FVP CAN stays loopback-only.

.. code-block:: console

  $ sudo ip tuntap add dev tap0 mode tap user "$(id -un)" 2>/dev/null || true
  $ sudo ip addr replace 192.168.10.1/24 dev tap0
  $ sudo ip link set dev tap0 up
  $ sudo ip link add vcan0 type vcan
  $ sudo ip link set up vcan0
  $ python3 demo/can_tunnel_bridge/gateway.py --bind 192.168.10.1 --port 5555
  $ ./build.sh --platform zephyr-fvp --network tap -d build/zephyr-fvp-tap
  $ west build -d build/zephyr-fvp-tap --target run
  $ python3 demo/can_carla_bridge/bridge.py --interface vcan0 --timeout 5 \
      --ego-role ego_vehicle

The ``fvp-tap`` controller image publishes on DDS only, so nothing reaches
the gateway yet (see the note at the top). The UDP tunnel runs in the
``--can-output-test`` program on the tap network
(``actuation_module/test/run-fvp-tap-tunnel.sh``, :doc:`testing`).

FVP is not real-time; use a larger ``--timeout`` than the 0.5 s POSIX default.
Closed-loop still starts Open AD Kit ``safety-island-carla-simulation`` first.
Apply its ``docker-compose.fvp.yaml`` overlay so the domain-bridge's domain 2
binds to ``tap0``.
