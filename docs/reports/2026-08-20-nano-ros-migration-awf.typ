// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Build: typst compile docs/reports/2026-08-20-nano-ros-migration-awf.typ

#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

#set document(
  title: "Porting the Autoware Safety Island onto nano-ros",
  author: "NEWSLab, National Taiwan University",
)
#set page(paper: "a4", margin: (x: 2.4cm, y: 2.6cm), numbering: "1")
#set text(font: "New Computer Modern", size: 10.5pt)
#set par(justify: true)
#set heading(numbering: "1.1")
#show link: set text(fill: rgb("#1a4a8a"))
#show raw.where(block: false): it => box(fill: luma(240), inset: (x: 2pt), outset: (y: 2pt), radius: 2pt, it)
#show figure: set block(breakable: true)

#let dnode(pos, body, w: auto, fill: luma(248)) = node(
  pos, body, width: w, fill: fill, stroke: 0.6pt + luma(100),
  corner-radius: 3pt, inset: 6pt,
)

#align(center)[
  #text(17pt, weight: "bold")[
    Porting the Autoware Safety Island onto nano-ros:\
    a Reference-Consumer Migration Study
  ]
  #v(6pt)
  #text(11pt)[NEWSLab, National Taiwan University]
  #v(2pt)
  #text(9.5pt, fill: luma(90))[Technical report for the Autoware Foundation — 2026-08-20 (rev. 2)]
]

#v(8pt)

#align(center, block(width: 88%)[
  #set text(9.5pt)
  #set par(justify: true)
  *Abstract.* The Autoware Safety Island (ASI) runs Autoware's trajectory
  follower --- MPC lateral and PID longitudinal control --- as a standalone
  application on a safety-class Arm processor, exchanging commands with a
  full Autoware stack over DDS. This report documents the migration of ASI's
  Zephyr targets from a hand-glued CycloneDDS port onto _nano-ros_, a
  lightweight `no_std` ROS 2 client library for embedded RTOSes. We show how
  nano-ros's workspace concepts (component node, bringup, and generated
  entry packages) restructure the firmware, what changed in the repository
  by category, how the Arm FVP integration works, and the outcome of a
  modernization step that advanced the middleware pin by $approx 2,400$
  commits: eleven "walls" with root causes, two upstream issues, and full
  re-validation --- six build modes, a five-phase emulator runtime suite,
  and a closed-loop demonstration against unmodified ROS 2 Humble Autoware
  at pre-migration control rates. ASI serves as nano-ros's canonical
  _reference consumer_: every integration failure is fixed upstream or
  tracked, never papered over downstream.
])

#v(6pt)

= Introduction

Safety architectures for autonomous driving separate a _safety island_ ---
a minimal, certifiable control path on a lockstep-capable processor --- from
the performance-oriented compute domain running the full autonomy stack.
ASI realizes this pattern for Autoware: the trajectory follower (MPC lateral
and PID longitudinal controllers, vendored unmodified from Autoware) runs on
an Arm Cortex-R82 target under Zephyr RTOS, consumes the planned trajectory
and vehicle state over DDS, and returns `autoware_control_msgs/Control`
commands (optionally mirrored onto CAN).

The original port owned its middleware: a vendored CycloneDDS tree, host IDL
tooling, and a bespoke node/executor shim --- exactly the code a safety
argument least wants to own. nano-ros (a `no_std` ROS 2 client for Zephyr,
FreeRTOS, NuttX and ThreadX with interchangeable RMW backends) replaces that
glue with a maintained, wire-compatible middleware layer. The migration was
run as a _reference-consumer_ engagement: ASI is nano-ros's named consumer
archetype, and every consumer-surfaced defect is intaken upstream rather
than worked around silently.

= System overview

@fig-loop shows the validated closed loop. An unmodified Autoware container
(ROS 2 Humble, `rmw_cyclonedds`) runs the planning simulator on DDS
domain 1; a DDS bridge relays the five controller inputs to domain 2, which
is pinned to a host TAP interface; the island on the Arm FVP consumes them
and publishes control commands back through the same path. There is no type
adaptation anywhere: nano-ros pins its CycloneDDS fork to the 0.10.5
release ROS Humble ships and emits `rmw_cyclonedds`-compatible type names
and CDR, so interoperability holds by construction (verified in both
directions with `ros2 topic hz`/`echo`).

#figure(
  diagram(
    spacing: (64pt, 16pt),
    node-stroke: 0.6pt + luma(100),
    edge-stroke: 0.7pt + luma(60),
    label-size: 7.5pt,
    label-sep: 2pt,

    dnode((0, 0), w: 118pt, align(center)[
      *Autoware container*\
      #text(8pt)[universe-20250207, Humble\ planning simulator + rviz]\
      #text(8pt, fill: luma(90))[DDS domain 1]
    ]),
    dnode((1, 0), w: 86pt, align(center)[
      *DDS bridge*\
      #text(8pt)[domain 1 $arrow.l.r$ 2 relay\ (compose service)]
    ]),
    dnode((2, 0), w: 150pt, fill: rgb("#eef3ea"), align(center)[
      *Safety island — Arm FVP*\
      #text(8pt)[
        `controller_pkg::Controller`\
        (Autoware MPC + PID, unmodified)\
        nros-cpp `ComponentNode` / executor\
        RMW: CycloneDDS 0.10.5 fork\
        Zephyr 3.7, Cortex-R82 SMP-4
      ]\
      #text(8pt, fill: luma(90))[DDS domain 2]
    ]),

    edge((0, 0), (1, 0), "->", shift: 8pt, label-side: left,
      text(7pt)[5 input topics\ (traj \@ 10 Hz)]),
    edge((1, 0), (2, 0), "->", shift: 8pt, label-side: left,
      text(7pt)[tap0]),
    edge((2, 0), (1, 0), "->", shift: 8pt, label-side: left,
      text(7pt)[`Control` #sym.approx 19 Hz+]),
    edge((1, 0), (0, 0), "->", shift: 8pt, label-side: left,
      text(7pt)[`…/control_cmd`]),
  ),
  caption: [The closed-loop demo (`scripts/run-tap-demo.sh`). The island's
  smsc-91c111 NIC model attaches to the host TAP; both DDS sides run stock
  CycloneDDS wire format.],
) <fig-loop>

= nano-ros concepts in the firmware

nano-ros structures an application as three roles, and the port maps ASI
onto them directly:

- *Node package* — `actuation_module/src/controller_pkg/`: the controller as
  a _component_. `controller_pkg::Controller` derives from the vendored
  Autoware controller (now a plain implementation library) so the package
  directory and registered class satisfy nano-ros's
  `<pkg-dir>::<Class>` identity rule; `NROS_COMPONENT(Controller)`
  registers it with an rclcpp shape marker. The base class uses the
  rclcpp-faithful `nros::ComponentNode` surface: `declare_parameter`
  (150+ MPC/PID parameters), member-function-pointer
  `create_subscription`/`create_timer`, value-typed publishers, and
  KEEP_LAST-1 QoS on every input.
- *Bringup package* — `actuation_module/src/controller_bringup/`:
  language-agnostic topology. `system.toml` + `launch/system.launch.xml`
  declare the node, its remappings and its 74 launch parameters;
  `play_launch resolve` turns them into a _SystemModel_ (a fully resolved,
  reproducible description with pinned inputs).
- *Entry package* — generated, never hand-written. One CMake call bakes the
  bootable image from the model (@fig-entry); the generated `main` seeds
  parameters, constructs components by placement-new with executor handles,
  waits on the board's network hook, and spins. The retired imperative
  `main.cpp` is fully superseded --- application liveness markers moved into
  the component constructor as a consequence.

#figure(
  diagram(
    spacing: (34pt, 18pt),
    label-sep: 2pt,
    node-stroke: 0.6pt + luma(100),
    edge-stroke: 0.7pt + luma(60),
    label-size: 7.5pt,

    dnode((0, 0), w: 105pt, align(center)[
      `system.toml`\ `launch/system.launch.xml`\
      #text(8pt, fill: luma(90))[bringup pkg (authored)]
    ]),
    dnode((1, 0), w: 95pt, align(center)[
      `config/`\ `system_model.yaml`\
      #text(8pt, fill: luma(90))[SystemModel (resolved)]
    ]),
    dnode((2, 0), w: 120pt, align(center)[
      generated entry TU\ + components stub\
      #text(8pt, fill: luma(90))[`nano_ros_add_executable(`\ `... MODEL ... TYPED)`]
    ]),
    dnode((3, 0), w: 78pt, align(center)[
      `zephyr.elf`\
      #text(8pt, fill: luma(90))[one fused image]
    ]),
    dnode((1, 1), w: 105pt, align(center)[
      ten `msg_ros/` pkgs\
      #text(8pt, fill: luma(90))[`nros_generate_interfaces()`]
    ]),
    dnode((2, 1), w: 150pt, align(center)[
      #text(8.5pt)[C++ value types (fixed-capacity) ·\
      per-pkg Rust FFI crates ·\
      CycloneDDS descriptors + idlc TUs]
    ]),

    edge((0, 0), (1, 0), "->", text(7pt)[resolve]),
    edge((1, 0), (2, 0), "->", [`nros` codegen]),
    edge((2, 0), (3, 0), "->", [west/CMake\ link]),
    edge((1, 1), (2, 1), "->"),
    edge((2, 1), (3, 0), "->"),
  ),
  caption: [Declarative bringup to bootable image. The launch topology and
  the interface packages are data; everything executable is generated.],
) <fig-entry>

= What changed: organization and code

The port left the vendored Autoware algorithms untouched and concentrated
change in the integration layers. By category, with representative examples:

#figure(
  align(left, block(width: 100%)[
    #set text(8.6pt)
    #table(
      columns: (auto, 1fr, 1.15fr),
      inset: 4.5pt,
      stroke: 0.4pt + luma(160),
      table.header([*Category*], [*Organization*], [*Representative changes*]),
      [Dependencies],
      [nano-ros as git submodule `modules/nros`, lockstep with the `west.yml` revision; vendored CycloneDDS retired from the Zephyr path (FreeRTOS targets untouched)],
      [`.gitmodules`, `actuation_module/west.yml` (zephyr v3.7.0 + zephyr-lang-rust pinned per nano-ros's contract)],
      [Build glue],
      [`build.sh` drives the nros CLI (host build, codegen tool handoff, board-id mapping, FVP flags); consumer patches are idempotent scripts],
      [`-D_NANO_ROS_CODEGEN_TOOL=...`, `NROS_MAX_PARAMETERS=256` / `NROS_EXECUTOR_MAX_CBS=16` / `NROS_SUBSCRIPTION_BUFFER_SIZE=16384`, `scripts/patches/nros-cpp-embedded-alloc-patch.sh`],
      [Node layer],
      [controller re-homed as component pkg `controller_pkg/`; polling shim `common/node/node_nros.hpp` retained for test images only],
      [`NROS_COMPONENT(Controller)`; ctor-owned boot markers; one-time `nros::init()` in the shim; cooperative stop flag replacing `pthread_cancel`],
      [Messages],
      [ten ROS interface pkgs vendored as `.msg` sources; a dual-mode umbrella maps ASI aliases onto generated C++ types],
      [`autoware_msgs/messages.hpp` (`TrajectoryMsg_Raw`, sentinel `_desc` stubs); fixed-capacity sequences (250-point trajectory bound)],
      [Tests],
      [five on-target programs kept middleware-honest through the umbrella],
      [`unit_test.cpp`, `dds_loopback_test.cpp` on typed pub/sub; `can_output_test.cpp` on Zephyr 3.7 CAN API],
      [Provisioning],
      [thin host bootstrap + one-command demo; no sudo ever executed by scripts],
      [`scripts/bootstrap-asi.sh` (west, SDK, CLI, board provisioning, SDK-store `idlc`), `scripts/run-tap-demo.sh`, `scripts/setup-tap.sh`],
    )
  ]),
  caption: [Change surface by category. Vendored Autoware component logic:
  zero changes beyond the port's adapter seams.],
)

= FVP integration

The Arm FVP_BaseR_AEMv8R (Cortex-R82, SMP-4) is the reference platform, and
its integration is board-crate-driven rather than hand-glued:

- *Board bundle.* nano-ros ships
  `packages/boards/nros-board-zephyr/boards/fvp-aemv8r-smp/` with a
  `board.cmake` single source of truth: hardware-model-v2 board id
  `fvp_baser_aemv8r/fvp_aemv8r_aarch64/smp`, toolchain `aarch64-zephyr-elf`,
  default RMW CycloneDDS, Rust target `aarch64-unknown-none`, runner
  `armfvp`, plus the board's Kconfig/DTS fragments and a
  `zephyr-rust-support` module. `nano_ros_use_board(fvp-aemv8r-smp)` before
  `find_package(Zephyr)` layers all of it in; `nros board info` prints the
  resolved contract.
- *NIC and networking.* The model's smsc-91c111 NIC is off by default;
  `build.sh` enables it (`-C bp.smsc_91c111.enabled=1`, promiscuous for the
  bridge path). Two profiles: FVP user-mode networking (DHCP; used by CI)
  and the TAP profile (`--network tap`: `-C bp.hostbridge.userNetworking=0
  -C bp.hostbridge.interfaceName=tap0`, DDS domain 2 pinned in the board
  conf) for the demo. IGMP is enabled for SPDP multicast join (fixed in the
  CycloneDDS fork during phase 3).
- *Run model.* `west build --target run` launches the FVP through Zephyr's
  `armfvp` runner --- no hand-rolled launch scripts. One model flag matters
  operationally: `-C cache_state_modelled=0`; with the default the model
  crawls $approx 1000 times$ under busy code, which presents as a "hang" at
  network bring-up.
- *CI.* A five-phase runtime suite downloads the sha-pinned FVP from Arm's
  public CDN and runs: full controller boot to its liveness markers; the
  on-target unit suite; a DDS loopback; CAN output over Zephyr's CAN
  loopback; and the TAP image build. The same script runs unchanged on a
  developer host (`.github/scripts/run-zephyr-fvp-ci.sh`).
- *Sizing.* The full image links to 9.7 MB of the FVP's 128 MB RAM; the
  build-time knobs above bound the parameter pool, executor slots, and the
  subscription buffer (an 8.8 kB trajectory must fit a single buffer).

= The 2026-08-20 modernization

The step advanced the nano-ros pin from `7dfe4fe4e` (2026-07-21) to
`eace28852` (2026-08-20) --- $approx 2,400$ upstream commits --- and adopted
the submodule layout. Eleven walls were logged (@tab-walls); none touched
application logic. An earlier advance (July 2026) had surfaced eight walls,
all fixed upstream within the cycle; notably, this jump produced _no_
regression in any area an earlier wall had hardened.

#figure(
  align(left, block(width: 100%)[
    #set text(8.6pt)
    #table(
      columns: (auto, 1fr, 1fr, auto),
      inset: 4.5pt,
      stroke: 0.4pt + luma(160),
      table.header([*\#*], [*Symptom*], [*Root cause*], [*Disposition*]),
      [1], [`nros setup board` rejects the board], [CLI resolves the retired per-board crate path; bundle boards moved in an upstream refactor], [Upstream issue \#0729; steps inlined downstream],
      [2], [Configure fails: host `idlc` not found], [Host CycloneDDS tooling moved to the CLI-managed SDK store], [Provision via `nros setup <board> --rmw cyclonedds`],
      [3], [Board-facts rung silently absent], [Facts resolver needs the nano-ros checkout path outside its own tree], [`NROS_REPO_DIR` exported; residual is \#0729's class],
      [4], [`nros-cpp` fails to compile (E0599)], [Embedded C++ CycloneDDS feature set omits `alloc` while an error-mapper arm references an alloc-gated variant; masked upstream by `native_sim`'s `std`], [Upstream issue \#0730; self-retiring downstream patch],
      [5], [Test programs: missing headers, unknown type names], [Flat idlc-name compatibility layer retired; typed C++ API is now the only publisher/subscriber surface], [Tests migrated onto the dual-mode message umbrella],
      [6], [`CAN_FILTER_DATA` undeclared], [Zephyr 3.7 removed the flag; the CAN test had never been rebuilt on 3.7], [Standard-ID filter is `flags = 0`],
      [7], [Entry panic policy changed], [Upstream default moved from halt to the platform's `k_panic()`], [Accepted; loud fatal is preferable for a safety island],
      [8], [Sizing knobs went live], [Previously inert Kconfig knobs are now forwarded; environment overrides Kconfig], [Audited: build-time exports still authoritative],
      [9], [Boot markers never printed], [Markers lived in the retired imperative `main.cpp`; the generated entry prints no application banner], [Component constructor now owns the markers],
      [10], [Tests: `create_node` returns `NOT_INIT`], [Entry-less test images never initialized the runtime], [Shim performs one-time `nros::init()`],
      [11], [Test hangs on node stop], [`pthread_cancel` is deferred-only on Zephyr's POSIX layer; the poll loop has no cancellation point], [Cooperative stop flag replaces cancel],
    )
  ]),
  caption: [Wall ledger for the $approx 2,400$-commit pin advance. Full
  details in the repository's phase-3 roadmap document.],
) <tab-walls>

Three observations generalize. *Latent-validation debt surfaces on
middleware moves*: walls 6, 9, 10, 11 were pre-existing gaps that the first
complete runtime re-validation exposed, not regressions. *Coverage gaps are
pairwise, not per-axis*: wall 4's failing coordinate is the combination
(embedded Zephyr $times$ C++ $times$ CycloneDDS); each axis value was
covered upstream, the pairing was not. *Consumer workarounds should be
designed to die*: both downstream workarounds are idempotent scripts that
detect the upstream fix and retire themselves.

= Validation

*Build.* Six firmware modes from one branch: full controller, unit test,
DDS loopback, CAN output, DDS publisher/subscriber.

*Runtime.* The five-phase FVP suite passes end to end (boot markers,
`All Tests Passed`, DDS loopback, CAN output, TAP build).

*Closed loop.* With the stack of @fig-loop brought up headless (ego pose
and goal seeded from the command line), the planner streams the trajectory
at 10 Hz; the island's MPC engages --- from the spawn position it correctly
commands an emergency stop on excessive tracking error --- and publishes
control commands back onto domain 1 at 19 Hz and above, matching the
pre-modernization baseline. `scripts/run-tap-demo.sh` reproduces the run,
including the rate check, in one command. Interoperability was additionally
spot-checked at field level with `ros2 topic echo` on the Humble side.

= Lessons for the ecosystem

+ *A reference consumer is cheap leverage for a middleware project* ---
  eleven walls in one step, two genuine upstream bugs invisible to the
  project's own CI.
+ *Pin in lockstep, and make the pin visible* --- one submodule pointer plus
  one manifest revision, required to agree.
+ *Generated entries beat imperative boot code* --- but application-level
  observability must then be owned by application components.
+ *Treat provisioning as data* --- toolchains, RMW sources and patch sets
  come from nano-ros's SDK index via idempotent commands; the consumer
  bootstrap stays thin across upstream refactors.
+ *Re-run everything on every move* --- the costliest walls hid behind
  validation that had silently stopped running.

= Status and future work

The Zephyr FVP target is fully migrated and validated on the modern
nano-ros pin. Open items: S32Z270 board parity (upstream board bundle
pending), moving the FreeRTOS targets onto nano-ros's platform layer
(retiring the vendored CycloneDDS entirely), adopting the launch-resolved
entry spelling end-to-end, a long-duration soak, and upstreaming
resolutions for issues \#0729/\#0730.

#v(4pt)
#line(length: 30%, stroke: 0.5pt + luma(140))
#text(8.5pt, fill: luma(90))[
  Sources: `docs/roadmap/phase-3-modern-nano-ros-migration.md` (wall ledger,
  runbook), `docs/roadmap/phase-1*.md`, `docs/design/workspace_mode.rst`,
  nano-ros book chapter _Importing a Board Crate_, nano-ros issues
  \#0729/\#0730. Repository: `github.com/newslabntu/autoware-safety-island`,
  branch `nano-ros`.
]
