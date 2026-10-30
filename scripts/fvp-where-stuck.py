"""Attach to the running FVP over Iris, stop it, and report where each core is.

Nine bisect probes would each cost a build and a boot, over a signal that has
already proven flaky. The model exposes a debug server; asking the stuck target
what it is executing answers the question directly.
"""
import subprocess
import sys

FVP = "/home/aeon/repos/autoware-safety-island/tools/fvp/FVP_Base_AEMv8R_11.31_28"
sys.path.insert(0, FVP + "/Iris/Python")

import iris.debug  # noqa: E402

port = int(sys.argv[1])
elf = sys.argv[2]

model = iris.debug.NetworkModel("localhost", port)
cpus = model.get_cpus()
print(f"cores: {len(cpus)}")

model.stop()

addrs = []
for i, cpu in enumerate(cpus):
    try:
        pc = cpu.read_register("PC")
    except Exception:
        try:
            pc = cpu.get_pc()
        except Exception as e:  # noqa: BLE001
            print(f"  core {i}: PC unavailable ({e})")
            continue
    print(f"  core {i}: PC = 0x{pc:016x}")
    addrs.append(pc)

    # A couple of samples per core: a spin shows the same small address range
    # every time, which distinguishes "looping here" from "passing through".
    for _ in range(3):
        model.run(blocking=False)
        model.stop()
        try:
            pc2 = cpu.read_register("PC")
            print(f"           resample = 0x{pc2:016x}")
            addrs.append(pc2)
        except Exception:
            break

if addrs:
    print("\n=== symbols ===")
    out = subprocess.run(
        ["addr2line", "-f", "-C", "-e", elf] + [hex(a) for a in addrs],
        capture_output=True, text=True)
    print(out.stdout or out.stderr)
