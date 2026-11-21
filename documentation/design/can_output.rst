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

The CAN output goes through nano-ros's platform CAN frame driver
(``<nros/platform_can.h>``, RFC-0132) behind one island wrapper,
``common/can/can_platform.hpp``. The board selects the backend and the image
names the device; the island keeps the frame ids, the payload layout and the
classic / FD choice. Whether an image can send CAN at all:

- ``zephyr-fvp``: not built (``CONFIG_CONTROL_CMD_CAN_OUTPUT`` off). The tap
  network's ``--can-output-test`` program builds it over the UDP tunnel, the
  island's own driver (``asi_common/src/zephyr/can_udp_tunnel_driver.cpp``).
- ``zephyr-s32z``: built (native CAN, nano-ros's Zephyr backend).
- ``freertos-posix``: built, on nano-ros's SocketCAN backend. The image names
  its device, ``[image.freertos-posix.can] device = "vcan0"`` in
  ``controller_bringup/system.toml``.
- ``freertos-an536``, ``freertos-s32z2``: built, on nano-ros's fail-loud
  defaults: the CAN open returns "not supported", so a CAN mode fails at
  start (``CAN_ONLY`` exits; ``DDS_AND_CAN`` keeps DDS).
- The census's host build links nano-ros's CAN mock.

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
CAN-FD frame ``0x103`` when the launch arg ``can_format`` is ``fd``. That mode
is opt-in and documented in :doc:`can_fd`; every other runtime stays classic.

**********************
Backends
**********************

Zephyr uses the ``nros,can`` chosen device, else ``zephyr,canbus``. On the
S32Z270 RTU0 that is ``&can0``, which Zephyr's own board devicetree
(``s32z2xxdc2_s32z270_rtu0.dts``) chooses.
Real bus validation requires the board CAN pins to be connected to an external
CAN transceiver and bus.

``freertos-posix`` uses Linux SocketCAN on the image's device
(``[image.<id>.can] device``). To use another interface, change that row.
The Zephyr test program ``--can-output-test``
(``actuation_module/test/can_output_test.cpp``) validates the encoder and
the output modes over the FVP's CAN loopback controller, or over the UDP
tunnel on the tap network.

Host SocketCAN (``vcan`` or a real adapter), the Zephyr FVP UDP tunnel, and
the CARLA ego bridge are specified in :doc:`can_carla_integration` and
:doc:`can_carla_implementation_plan`. Those paths sit on top of this
placeholder contract; they do not change the frame layout.
