..
 # Copyright (c) 2026, Arm Limited.
 #
 # SPDX-License-Identifier: Apache-2.0

##############
CAN output
##############

The controller can send the final
``autoware_control_msgs/msg/Control`` command over DDS, CAN, or both. DDS
inputs are unchanged; only the final control-command output is gated by this
mode.

**********************
Output modes
**********************

The launch arg ``control_output`` (``system.launch.xml``, passed to the node
as a parameter) selects one mode at run time:

- ``DDS_ONLY`` (the default) — publish
  ``/control/trajectory_follower/control_cmd`` only.
- ``CAN_ONLY`` — send CAN frames only.
- ``DDS_AND_CAN`` — publish DDS and send CAN frames.

An image binds it in its ``[image.<id>] args`` row of ``system.toml``; no
image does today, so every image runs ``DDS_ONLY``. An unknown value falls
back to ``DDS_ONLY``.

Whether an image can send CAN at all is a build fact,
``CONFIG_CONTROL_CMD_CAN_OUTPUT``:

- ``zephyr-fvp``: not built. The tap network's ``--can-output-test``
  program builds it over the UDP tunnel.
- ``zephyr-s32z``: built (native CAN).
- ``freertos-posix``: built, on the CAN stub (no SocketCAN in the image).
  SocketCAN runs in the ``--can-output-test`` host program
  ``can_vcan_sender`` with ``SAFETY_ISLAND_CAN_IFACE``. The in-memory mock
  is test-only.
- ``freertos-s32z2``: the CAN stub; CAN is not part of this stack there.

``build.sh`` has no ``--control-output`` option.

**********************
Frame format
**********************

The CAN mapping is a placeholder contract intended for integration testing and
early bring-up. Each command produces three classic 8-byte CAN frames:

.. list-table::
   :widths: 20 35 45
   :header-rows: 1

   * - CAN ID
     - Payload
     - Scaling
   * - ``0x100``
     - steering angle, steering rate
     - signed little-endian ``int32``, value * 1,000,000
   * - ``0x101``
     - velocity, acceleration
     - signed little-endian ``int32``, value * 1,000
   * - ``0x102``
     - output mode, validity flags, sequence, timestamp
     - mode byte, flags byte, ``uint16`` sequence, ``uint32`` timestamp in ms

Non-finite command values are rejected before any CAN frame is sent.

``freertos-posix`` can instead send the same three payloads as one 24-byte
CAN-FD frame ``0x103`` when ``SAFETY_ISLAND_CAN_FORMAT=fd`` is set. That mode
is opt-in and documented in :doc:`can_fd`; every other runtime stays classic.

**********************
Backends
**********************

Zephyr uses the selected ``zephyr,canbus`` device. On the S32Z270 RTU0 that is
``&can0``, which Zephyr's own board devicetree
(``s32z2xxdc2_s32z270_rtu0.dts``) chooses.
Real bus validation requires the board CAN pins to be connected to an external
CAN transceiver and bus.

``freertos-posix`` uses Linux SocketCAN when CAN output is enabled and
``SAFETY_ISLAND_CAN_IFACE`` is set. The in-memory mock is compiled only
into ``--can-output-test``. That test program
(``actuation_module/test/can_output_test.cpp``) validates the encoder,
output modes, and recorded mock frames.

Host SocketCAN (``vcan`` or a real adapter), the Zephyr FVP UDP tunnel, and
the CARLA ego bridge are specified in :doc:`can_carla_integration` and
:doc:`can_carla_implementation_plan`. Those paths sit on top of this
placeholder contract; they do not change the frame layout.
