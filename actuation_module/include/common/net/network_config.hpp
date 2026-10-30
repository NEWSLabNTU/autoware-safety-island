// Copyright (c) 2022-2026, Arm Limited / NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 1C re-home of common/dds/network_config.hpp. The DHCP / static
// IP bring-up is orthogonal to the RMW choice — keeping it under
// common/dds/ only made sense while Cyclone was the only backend. The
// new path lives under common/net/ so common/dds/ can be deleted
// outright after the nano-ros cutover.
//
// During the migration window both headers coexist. ASI's
// platform/zephyr/zephyr_network.h includes whichever one matches the
// chosen build path.

#ifndef COMMON__NET__NETWORK_CONFIG_HPP_
#define COMMON__NET__NETWORK_CONFIG_HPP_

int configure_network(void);

#endif  // COMMON__NET__NETWORK_CONFIG_HPP_
