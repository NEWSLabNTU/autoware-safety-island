// Copyright (c) 2025, Arm Limited.
// SPDX-License-Identifier: Apache-2.0

#ifndef PLATFORM__ZEPHYR__NETWORK_H_
#define PLATFORM__ZEPHYR__NETWORK_H_

// Phase 1C router: nano-ros shim path moves network_config.hpp out of
// common/dds/ (which gets deleted post-cutover) and into common/net/.
// Toggle is the same ASI_USE_NANO_ROS used by node.hpp +
// autoware_msgs/CMakeLists.txt.
#ifdef ASI_USE_NANO_ROS
#include "common/net/network_config.hpp"
#else
#include "common/dds/network_config.hpp"
#endif

#endif  // PLATFORM__ZEPHYR__NETWORK_H_
