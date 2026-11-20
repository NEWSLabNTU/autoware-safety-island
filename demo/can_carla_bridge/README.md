# CAN-CARLA bridge

Open-loop host path for PR 1: `freertos-posix` writes classic frames to
SocketCAN; this process decodes `0x100` / `0x101` / `0x102` and applies
`carla.VehicleAckermannControl`.

## Host setup

```bash
sudo ip link add vcan0 type vcan
sudo ip link set up vcan0
pip install -r requirements.txt
```

Build and run the Safety Island (repository root):

```bash
./build.sh --platform freertos-posix -d build/freertos-posix
CYCLONEDDS_URI='<General><Interfaces><NetworkInterface name="lo"/></Interfaces></General>' \
  SAFETY_ISLAND_CAN_IFACE=vcan0 ./build/freertos-posix/actuation_posix_entry
```

`CAN_ONLY` is not built on the nano-ros branch: `build.sh` has no
`--control-output`, and the `freertos-posix` image is fixed at `DDS_AND_CAN`
on the CAN stub (no SocketCAN), so nothing reaches `vcan0` yet. The CAN path
is tested by `./build.sh --platform freertos-posix --can-output-test`
(`actuation_module/test/run-vcan-roundtrip.sh`).

Feed canned DDS inputs on domain 2 (rosbag or `--dds-publisher`). Then:

```bash
python3 bridge.py --interface vcan0 --dry-run
python3 bridge.py --interface vcan0 --host 127.0.0.1 --port 2000 --ego-role ego_vehicle
```

`--dry-run` prints decoded Ackermann fields and does not need CARLA.
The live bridge requires exactly one vehicle with `role_name=hero` by default;
use `--ego-role NAME` for another role or `--ego-id ID` to select a specific
vehicle. It fails rather than driving an arbitrary vehicle if selection is
missing or ambiguous.
For Open AD Kit, pass `--ego-role ego_vehicle` (see
`documentation/user_guide/can_carla_closed_loop.rst`). Watchdog timeout defaults to 0.5 s.

CAN-FD is optional: run the Safety Island with
`SAFETY_ISLAND_CAN_FORMAT=fd` and the bridge with `--can-format fd`. The bridge
then decodes one 24-byte `0x103` frame instead of
`0x100`/`0x101`/`0x102`.
