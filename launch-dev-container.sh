#! /bin/bash

# Copyright (c) 2024-2026, Arm Limited / NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0

COLOR_YELLOW="\e[33m"
COLOR_RESET="\e[0m"

# Check if xhost is available
if command -v xhost >/dev/null 2>&1; then
    xhost +
else
    echo -e "${COLOR_YELLOW}Warning: xhost command not found on host machine. X11 forwarding may not work properly.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}----------------------------------------------------------${COLOR_RESET}"
fi

# Run as host UID/GID so files created in the bind-mounted source tree
# are owned by the host user. Image bakes `dev:1000` + fixuid; fixuid
# rewrites /etc/passwd at startup so $HOME and the bind-mount end up
# owned by whichever UID Docker drops us into.
HOST_UID=$(id -u)
HOST_GID=$(id -g)

mkdir -p "${HOME}/.ccache"

docker run --rm -it --name autoware-safety-island-devcontainer \
    --privileged \
    --network host \
    --user "${HOST_UID}:${HOST_GID}" \
    -v "$HOME/.ccache:/home/dev/.ccache" \
    -v "$(pwd):/autoware-safety-island" \
    -w "/autoware-safety-island" \
    ghcr.io/autowarefoundation/autoware-safety-island:devcontainer
