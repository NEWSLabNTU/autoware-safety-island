/*
 * Copyright (c) 2026, NEWSLab NTU.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Phase 1A smoke — minimal nros-cpp Int32 publisher. Goal: prove the
 * nano-ros Zephyr module + nros-cpp API link cleanly into ASI's build
 * tree for the FVP target. Adapted from
 * nano-ros-autoware/examples/zephyr/cpp/dds/talker/src/main.cpp.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(asi_nros_smoke, LOG_LEVEL_INF);

#define NROS_TRY_LOG(file, line, expr, ret) \
    LOG_ERR("%s:%d %s -> %d", (file), (line), (expr), (int)(ret))

#include <nros/app_main.h>
#include <nros/nros.hpp>

#include "std_msgs.hpp"

int nros_app_main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    LOG_INF("ASI nano-ros smoke (Phase 1A)");
    LOG_INF("==============================");

    NROS_TRY_RET(nros::init("", CONFIG_NROS_DOMAIN_ID), 1);

    nros::Node node;
    NROS_TRY_RET(nros::create_node(node, "asi_nano_ros_smoke"), 1);

    nros::Publisher<std_msgs::msg::Int32> pub;
    NROS_TRY_RET(node.create_publisher(pub, "/asi/smoke/counter"), 1);

    LOG_INF("Publishing /asi/smoke/counter ...");

    int32_t count = 0;
    while (true) {
        count++;
        std_msgs::msg::Int32 msg;
        msg.data = count;
        nros::Result ret = pub.publish(msg);
        if (ret.ok()) {
            LOG_INF("Published: %d", count);
        } else {
            LOG_ERR("Publish failed: %d", ret.raw());
        }
        k_sleep(K_SECONDS(1));
    }

    nros::shutdown();
    return 0;
}

NROS_APP_MAIN_REGISTER_ZEPHYR()
