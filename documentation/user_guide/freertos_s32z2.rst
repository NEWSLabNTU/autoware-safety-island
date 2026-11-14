..
 # Copyright (c) 2026, Arm Limited / NEWSLab NTU.
 #
 # SPDX-License-Identifier: Apache-2.0

##############
FreeRTOS S32Z2
##############

This guide covers the ``freertos-s32z2`` runtime target: FreeRTOS on the NXP
S32Z2 Cortex-R52 hardware path, built through the nano-ros workspace lane
(phase-4 W5.b). The retired vendored-CycloneDDS lane's bring-up notes live in
``actuation_module/src/s32z2_board_glue/README.md`` and
:doc:`/design/freertos-s32z2-bringup`.

.. note::

   ``freertos-s32z2`` is not a local validation target. Validate FreeRTOS DDS
   and controller behavior locally with :doc:`freertos_posix`, then treat
   ``freertos-s32z2`` as a bench-only hardware build that needs S32Z2-specific
   validation. Hardware smoke for the nano-ros lane is pending (phase-4 W5.b
   item 5).

*****
Build
*****

Without the NXP SDK the image link-completes against the board bundle's weak
fail-loud netif/tick stubs — this is the pre-hardware acceptance build:

.. code-block:: console

  $ ./build.sh --platform freertos-s32z2 -d build/freertos-s32z2

Output:

.. code-block:: text

  build/freertos-s32z2/src/freertos_s32z2_entry/actuation_s32z2_entry

The FreeRTOS kernel is env-provisioned: ``FREERTOS_DIR``/``FREERTOS_PORT``
default to the nano-ros-pinned kernel with the generic ``GCC/ARM_CRx_No_GIC``
port. For the NXP GIC port (hardware), stage the patched copy first:

.. code-block:: console

  $ scripts/provision-nxp-freertos.sh   # applies port.c.patch, prints the overrides

*******************
NXP-licensed pieces
*******************

The RTD NETC driver, PBcfg output and the CR52_GIC kernel port are NXP
Confidential — provisioned locally, never committed. The
``src/s32z2_board_glue`` package gates on ``S32_RTD_PATH``; wiring the RTD
sources into it is the first task of the hardware bring-up session. The
S32 Config Tools output lives in the private
``actuation_module/src/s32z2_board_glue/s32ct_config`` submodule.

******
Status
******

``freertos-s32z2`` is not part of the local validation flow. Treat it as a
hardware target that requires bench validation after build changes. The
nano-ros lane cross-links from a clean checkout; on-target parity with the
retired legacy baseline is the phase-4 W5.b item-5 acceptance.
