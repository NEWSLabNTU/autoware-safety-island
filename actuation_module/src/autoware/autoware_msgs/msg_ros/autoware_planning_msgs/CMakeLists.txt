# Phase 1B nros-codegen stub.
# Trajectory.msg carries the ASI-local [<=250] bound (see
# docs/MSG_PROVENANCE.md). nros's rosidl-parser accepts the syntax;
# C++ emitter produces nros::FixedSequence<TrajectoryPoint, 250>.
nros_generate_interfaces(autoware_planning_msgs LANGUAGE CPP
    DEPENDENCIES std_msgs geometry_msgs builtin_interfaces)
