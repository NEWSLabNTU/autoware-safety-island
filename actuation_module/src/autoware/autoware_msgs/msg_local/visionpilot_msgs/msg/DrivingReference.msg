# One VisionPilot path and speed/stop intent from a single camera cycle.
# Local .msg twin of upstream's msg/DrivingReference.idl. One difference:
# speed_horizon_mps is BOUNDED here ([<=100], vp_reference::kMaxHorizon) --
# nano-ros sizes every receive buffer from a derived bound, and a longer
# horizon is rejected by the SI anyway.

# When VP produced this reference (VP host clock).
builtin_interfaces/Time stamp
# Capture time of the camera frame this cycle came from.
builtin_interfaces/Time source_stamp
bool has_source_stamp
# VP process session and strictly increasing cycle counter.
uint32 session
uint64 cycle
# False when the upstream pipeline produced no usable reference this cycle.
bool valid
# Fused lane-center polynomial in base_link: y = a x^2 + b x + c.
bool path_valid
float64 path_a
float64 path_b
float64 path_c
float64 path_x_max_m
# Planned speed schedule: v m/s at t = i * horizon_dt_s.
float64 horizon_dt_s
float64[<=100] speed_horizon_mps
