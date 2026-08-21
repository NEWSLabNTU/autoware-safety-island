// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 4 W5.b — the STRONG netif override for the nano-ros S32Z270 board
// bundle (nano-ros phase-372 W3 seam).
//
// The bundle's `nros-board-s32z270-freertos/c/board_s32z270.c` ships WEAK
// fail-loud `nros_board_register_netif` / `nros_board_poll_netif` defaults,
// because the NETC ethernet driver is NXP RTD (NXP Confidential) and cannot
// live upstream. This TU is the consumer half: it provides the strong
// overrides on top of the SAME hardware-proven glue the legacy lane runs
// (`freertos_s32z2/lwip_bringup.c` + `ethif_shim.c` + the RTD PBcfg set),
// which this package compiles alongside when the NXP SDK is provisioned
// (see CMakeLists — without the SDK this whole package is skipped and the
// bundle's weak stubs say so at boot).
//
// Contract (mirrors the MPS2 LAN9118 strong override):
//   * `nros_board_register_netif()` — bring the netif up; return 0 when the
//     interface is registered and usable, negative otherwise. Blocking is
//     acceptable: the family's network_glue calls it once from the network
//     bring-up path before the RMW session opens.
//   * `nros_board_poll_netif()` — per-tick RX servicing for POLLED drivers.
//     The NETC driver is interrupt-driven with its own RX task in the
//     legacy glue, so this stays a no-op.

// Hardware-proven bring-up from the legacy lane: NETC + lwIP netif add +
// DHCP-less static config + RX task spawn. Blocks until link + IP are up.
extern int lwip_bring_up_blocking(void);

int nros_board_register_netif(void) {
    return lwip_bring_up_blocking();
}

void nros_board_poll_netif(void) {
    // Interrupt-driven (Eth_43_NETC RX IRQ -> RX task); nothing to poll.
}
