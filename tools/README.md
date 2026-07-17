# tools/ — local host tooling (gitignored)

Everything here is machine-local and NEVER committed (see `.gitignore`;
only this README is tracked).

## Layout

```
tools/
├── fvp/
│   ├── FVP_Base_AEMv8R_11.31_28_Linux_x86.tar.gz    # downloaded archives
│   ├── FVP_Base_AEMv8R_11.31_28_Linux_armv8.tar.gz  # (arm-host build, for reference)
│   └── FVP_Base_AEMv8R_11.31_28/                    # extracted x86 model
│       └── bin/FVP_BaseR_AEMv8R                     # the model binary
└── avh/
    ├── avh_key    # Corellium API token (chmod 600) — the source the root
    │              # .env's AVH_API_TOKEN was generated from
    └── avh.ovpn   # the device VPN profile (dashboard → Connect →
                   # Download OVPN File; chmod 600)
```

## Use

- **Local FVP** — point Zephyr's runner at the model:
  `export ARMFVP_BIN_PATH=$PWD/tools/fvp/FVP_Base_AEMv8R_11.31_28/bin`
  then `west build -d build/zephyr-fvp-tap --target run`
  (TAP first: `sudo ./scripts/setup-tap.sh`).
- **AVH VPN** — `sudo -b openvpn --config tools/avh/avh.ovpn`, then the
  device's console/gdb endpoints (dashboard *Connect* tab) are reachable;
  `./avh.py --deploy` uploads firmware via the API (config: root `.env`,
  see `template.env` + docs/user_guide/avh.rst).
