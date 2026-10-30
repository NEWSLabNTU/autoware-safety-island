# The only actuator-facing Safety Island output: one approved driving request
# per SI control cycle. SI is the only publisher. Local .msg twin of
# upstream's msg/ApprovedRequest.idl (identical fields and order).

# SI system clock when this request was produced.
builtin_interfaces/Time stamp
# SI boot/session identity (changes on SI restart).
uint32 session
# Strictly increasing output sequence within one SI session.
uint64 output_sequence
# 0 = NORMAL, 1 = SI_STOP, 2 = HOLD; anything else is treated as HOLD.
uint8 decision
# 0 = SI_CONTROL, 1 = VP_CONTROL
uint8 mode
# 0 = FOLLOWER, 1 = VP_COMMAND
uint8 selected_source
# VisionPilot cycle identity of the accepted input this output carries.
uint32 source_session
uint64 source_cycle
# Identity of the fault event that caused the current SI_STOP; 0 otherwise.
uint32 fault_id
# The actuation payload.
autoware_control_msgs/Control control
