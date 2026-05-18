# Phase 1B nros-codegen stub. tier4_debug_msgs is pinned to a SHA on
# tier4/universe branch (no stable Humble tag — see docs/MSG_PROVENANCE.md).
nros_generate_interfaces(tier4_debug_msgs LANGUAGE CPP
    DEPENDENCIES builtin_interfaces std_msgs)
