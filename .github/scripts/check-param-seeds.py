#!/usr/bin/env python3
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
"""Check the controller's parameters against what seeds them.

The controller's parameter values are controller_bringup/config/*.param.yaml
and the launch file's inline <param>s. Its C++ declare_parameter() defaults
state the same values only for nano-ros's metadata probe, which constructs
the node with no launch values. Three mistakes are silent at run time on
nano-ros, so this refuses them at build time, from what the build already
produced:

1. A declared parameter that no param file or inline <param> seeds runs on
   its C++ default, which nothing checks against the deployment.
2. More parameters than an image's parameter store holds
   (knobs.params.max_parameters): nano-ros stops the boot at the first
   declaration with no slot; this says so at build time.
3. A param file value of another type than the declaration (`kp: 1` for a
   double, `[1, 2]` for a double array). nano-ros is to refuse the boot for
   it, as upstream rclcpp does. Every double is a float literal.

Inputs: the census metadata (every declare_parameter<T>() the code runs, with
T), the launch record (the seeds), the param files, and each image's store
size as `nros dev image leaf-system` renders it.

usage: check-param-seeds.py <nros-plan dir> <bringup dir> <nros CLI>
  <nros-plan dir>  an image build's cmake/nros-plan (metadata/controller.json,
                   record.json)
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

NODE = "controller"
# census type -> the YAML value type it takes
TYPES = {
    "double": lambda v: isinstance(v, float),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "bool": lambda v: isinstance(v, bool),
    "string": lambda v: isinstance(v, str),
    "double_array": lambda v: isinstance(v, list) and all(isinstance(x, float) for x in v),
    "integer_array": lambda v: isinstance(v, list)
    and all(isinstance(x, int) and not isinstance(x, bool) for x in v),
    "bool_array": lambda v: isinstance(v, list) and all(isinstance(x, bool) for x in v),
    "string_array": lambda v: isinstance(v, list) and all(isinstance(x, str) for x in v),
}


def flatten(d, prefix=""):
    for k, v in d.items():
        if isinstance(v, dict):
            yield from flatten(v, prefix + k + ".")
        else:
            yield prefix + k, v


def store_sizes(bringup, nros):
    """max_parameters per image, as the image's build renders it."""
    images = re.findall(r"^\[image\.([A-Za-z0-9_-]+)\]", (bringup / "system.toml").read_text(), re.M)
    sizes = {}
    with tempfile.TemporaryDirectory() as tmp:
        for img in images:
            kd = pathlib.Path(tmp, img + ".kd")
            subprocess.run(
                [nros, "dev", "image", "leaf-system", str(bringup), "--image", img,
                 "--language", "cpp", "--kconfig-out", str(pathlib.Path(tmp, img + ".conf")),
                 "--image-env-out", str(pathlib.Path(tmp, img + ".env")),
                 "--kconfig-defaults-out", str(kd)],
                check=True, stdout=subprocess.DEVNULL)
            m = re.search(r"knobs params\.max_parameters = (\d+)", kd.read_text())
            sizes[img] = int(m.group(1)) if m else None
    return sizes


def main():
    plan_dir = pathlib.Path(sys.argv[1])
    bringup = pathlib.Path(sys.argv[2])
    nros = sys.argv[3]
    errors = []

    declared = {}
    for p in json.loads((plan_dir / "metadata" / f"{NODE}.json").read_text()).get("parameters", []):
        declared.setdefault(p["name"], p["type"])

    seeds = set()
    for node in json.loads((plan_dir / "record.json").read_text()).get("node", []):
        if node.get("name") == NODE:
            seeds.update(name for name, _ in node.get("params", []))

    unseeded = [n for n in declared if n not in seeds]
    if unseeded:
        errors.append("declared, but no param file or <param> seeds: " + ", ".join(unseeded))
    undeclared = sorted(seeds - set(declared))
    if undeclared:
        errors.append("seeded, but never declared (each costs a store slot): " + ", ".join(undeclared))

    files = sorted((bringup / "config").rglob("*.param.yaml"))
    for f in files:
        doc = yaml.safe_load(f.read_text())
        for key, block in doc.items():
            for name, value in flatten(block.get("ros__parameters", {})):
                t = declared.get(name)
                if t is None:
                    errors.append(f"{f.relative_to(bringup)}: {name} is declared nowhere")
                elif t not in TYPES:
                    errors.append(f"{f.relative_to(bringup)}: {name}: unknown declared type {t}")
                elif not TYPES[t](value):
                    errors.append(f"{f.relative_to(bringup)}: {name}: {value!r} is not a {t} "
                                  "(write a double as a float literal, 1.0 not 1)")

    sizes = store_sizes(bringup, nros)
    for img, size in sorted(sizes.items()):
        if size is None:
            errors.append(f"[image.{img}] states no knobs.params.max_parameters")
        elif size < len(declared):
            errors.append(f"[image.{img}] stores {size} parameters, the controller declares {len(declared)}")

    print(f"parameters: {len(declared)} declared, {len(seeds)} seeded, "
          f"{len(files)} param files; store sizes {sorted(set(sizes.values()), key=str)}")
    for e in errors:
        print("ERROR: " + e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
