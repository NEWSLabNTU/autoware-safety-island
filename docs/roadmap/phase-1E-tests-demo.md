# Phase 1E - tests, rosbag parity, and demo closure

**Goal.** Rebuild ASI's validation surface on the nano-ros path and prove
controller outputs remain comparable to checked-in expected data. ASI no
longer maintains a raw Cyclone test surface — `dds_pub.cpp` / `dds_sub.cpp`
/ `unit_test.cpp` either move to nros-cpp or are deleted in favor of
upstream nano-ros tests. Reuse `nros-tests` patterns (per-platform nextest
groups, Slirp networking, dedicated zenohd/agent ports) where they fit.

**Status.** Draft, not started. **Revised 2026-05-18** — architecture
pivot. Host-peer reference is stock `rmw_cyclonedds_cpp` (validated POSIX-
side in 117.12). Cyclone-on-Zephyr E2E added once Phase 1D lands.

**Parallelism.** Starts immediately for fixture inventory. Test work lands
incrementally after 1A–1D expose buildable seams.

## Upstream patterns to reuse

- `nros-tests` crate with `rstest` matrices, JUnit XML at
  `target/nextest/default/junit.xml`, per-platform nextest groups
  (`max-threads = 1`).
- Slirp networking for QEMU / native_sim (no TAP / sudo / bridges).
- Per-platform zenohd / agent ports prevent cross-test collisions.
- Subscriber-first, then publisher; 5–10 s stabilization window.
- Build isolation: nextest tests with different features building the same
  example MUST use `--target-dir`.
- `tests/run-test.sh` → `test-logs/latest/` for non-nextest harnesses.

## Test surfaces

| Surface | Today (Cyclone direct) | After migration |
|---|---|---|
| CAN unit test | `can_output_test.cpp` (middleware-independent) | unchanged |
| Unit DDS smoke | `unit_test.cpp` (Cyclone) | port to nros-cpp pub/sub via Cyclone RMW |
| Standalone publisher | `dds_pub.cpp` | port to nros-cpp publisher, OR delete and rely on nano-ros upstream tests |
| Standalone subscriber | `dds_sub.cpp` | port to nros-cpp subscriber, OR delete |
| Rosbag parity | `rosbag_test/` | replay → controller → YAML compare; topic names unchanged |
| Stock-RMW interop | absent | host `ros2 topic echo` w/ `rmw_cyclonedds_cpp` |

Default: delete `dds_pub.cpp` / `dds_sub.cpp`. nano-ros already covers raw
pub/sub at the upstream level. ASI's tests should focus on ASI-specific
behavior (controller output, CAN, rosbag parity).

## Work Items

- [ ] **1E.1 - Preserve CAN tests.**
  Keep `can_output_test.cpp` middleware-independent. No backend deps.
- [ ] **1E.2 - Rebuild unit DDS smoke as nros-cpp smoke.**
  Port `unit_test.cpp` to exercise node + timer + publisher + subscriber
  + callback dispatch through `nros-cpp` over Cyclone RMW. Or delete
  and rely on a small ASI-specific replacement that covers controller
  wiring rather than RMW basics.
- [ ] **1E.3 - Decide fate of `dds_pub.cpp` / `dds_sub.cpp`.**
  Either delete (preferred — nano-ros covers it upstream) or port to
  nros-cpp with the host-peer command documented (`ros2 topic pub/echo`
  + `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`).
- [ ] **1E.4 - Add rosbag comparison path.**
  Use existing `actuation_module/test/rosbag_test` inputs. Replay via
  nano-ros; compare `/control/trajectory_follower/control_cmd` against
  expected YAML. User-facing topic strings stay unchanged; wire uses
  `rt/` prefix automatically.
- [ ] **1E.5 - Add stock-RMW interop harness.**
  Host: ROS 2 Humble + `rmw_cyclonedds_cpp` 1.3.4 +
  `ros-humble-cyclonedds` 0.10.5. Confirm pub/sub + (optional) services
  round-trip with the conventions from Phase 1B. Mirror nano-ros 117.12
  POSIX E2E topology.
- [ ] **1E.6 - Document host setup + ASI test commands.**
  Update `docs/user_guide/testing.rst`: nano-ros checkout, `just
  cyclonedds setup`, ASI smoke build, host peer launch, expected
  artifacts, troubleshooting (backend discovery, domain ID, type-name
  mismatch).
- [ ] **1E.7 - CI split plan.**
  Mark fast local build smokes, host interop tests, FVP tests, and
  hardware-only S32Z tests so they can run as parallel jobs later.
  Distinguish ASI-owned jobs from nano-ros-owned jobs (CI for nano-ros
  itself lives upstream).

## Acceptance Criteria

- [ ] At least one nano-ros FVP smoke test builds from `./build.sh`.
- [ ] Stock `rmw_cyclonedds_cpp` peer observes a published ASI test
      topic without any nano-ros / nros-cpp tooling on the host side.
- [ ] Controller command output generated from existing rosbag inputs
      matches checked-in expected YAML within tolerance.
- [ ] CAN output tests still pass in middleware-independent mode.
- [ ] `dds_pub.cpp` / `dds_sub.cpp` either ported or deleted, documented.
- [ ] Docs list exact commands + expected artifacts + nano-ros checkout
      requirement.
- [ ] Test grouping identifies parallel-safe vs FVP/hardware-serialized
      jobs.

## Parallel Job Candidates

- `job-build-legacy`: current raw Cyclone `./build.sh` (regression guard
  until cutover, then deleted).
- `job-build-nano-ros-smoke`: nano-ros minimal publisher build.
- `job-codegen`: generated ASI interface compile-only check
  (`nros_generate_interfaces` + `nros_rmw_cyclonedds_add_idl_library`).
- `job-can`: CAN-only unit test build/run.
- `job-host-interop`: stock `rmw_cyclonedds_cpp` peer vs FVP smoke.
- `job-rosbag-parity`: rosbag replay + YAML comparison.

## Likely Files

- `actuation_module/test/unit_test.cpp` (port or replace)
- `actuation_module/test/dds_pub.cpp` (delete or port)
- `actuation_module/test/dds_sub.cpp` (delete or port)
- `actuation_module/test/can_output_test.cpp` (unchanged)
- `actuation_module/test/rosbag_test/*`
- `docs/user_guide/testing.rst`
- `.github/workflows/*`
- `~/repos/nano-ros-autoware/packages/dds/nros-rmw-cyclonedds/tests/posix_e2e.cpp` (reference)
