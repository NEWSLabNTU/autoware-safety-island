# Phase 1B nros-codegen stub. Upstream nests this msg under
# operation_mode/msg/; sync_msg_ros.sh flattens it to msg/ for the
# nros codegen resolver.
nros_generate_interfaces(autoware_adapi_v1_msgs LANGUAGE CPP
    DEPENDENCIES builtin_interfaces std_msgs geometry_msgs)
