#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# run-carla.sh -- the Safety Island in the loop on CARLA, one command.
#
# Reuses the L4 integration runner (L4SafetyIsland_Implementation, ci/runner:
# the l4si-ci-stack image with Autoware 2.0.0 + scenario-world-bridge, and
# CARLA 0.9.16 on the GPU) with this repository's island and swb project:
#   1. builds the freertos-posix-carla image and stages it with its libddsc
#      under build/carla-island (mounted read-only into the runner);
#   2. starts CARLA (compose project asi-carla, so an L4 run is not touched);
#   3. runs the runner's integration.sh with compose.island.yaml: swb's
#      drive_to_goal suite (project/) with the island as the ego's only
#      trajectory follower, then island-check.sh;
#   4. brings the compose project down.
#
# Usage:
#   L4SI_DIR=<L4 checkout> integration/carla/run-carla.sh
# Exit code: the runner's (0 passed, 1 failed, 2 error, 3 refused).
# Work directory: build/carla-work (state/, project/, artifacts/), the
# artifacts copied to log/carla/.
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
L4SI_DIR="${L4SI_DIR:?set L4SI_DIR to the L4SafetyIsland_Implementation checkout}"
COMPOSE=(docker compose -p asi-carla -f "$L4SI_DIR/ci/runner/compose.yaml"
         -f "$ROOT/integration/carla/compose.island.yaml")
STAGE="$ROOT/build/carla-island"

say() { echo "[carla] $*"; }

say "building the freertos-posix-carla island..."
(cd "$ROOT" && ./build.sh --platform freertos-posix-carla) >"$ROOT/log/carla-build.log" 2>&1 ||
    { tail -20 "$ROOT/log/carla-build.log"; exit 3; }
entry="$(readlink -f "$ROOT/build/freertos-posix-carla/actuation_posix_entry")"
ddsc="$(ldd "$entry" | awk '/libddsc/ {print $3}')"
[ -f "$ddsc" ] || { say "no libddsc for $entry"; exit 3; }
rm -rf "$STAGE" && mkdir -p "$STAGE/lib"
cp "$entry" "$STAGE/actuation_posix_entry"
cp -L "$ddsc" "$STAGE/lib/"
say "staged $(basename "$entry") + $(basename "$ddsc") in $STAGE"

export ASI_ROOT="$ROOT" HOST_UID="$(id -u)" HOST_GID="$(id -g)"
rm -rf "$ROOT/build/carla-work" && mkdir -p "$ROOT/build/carla-work"
down() { "${COMPOSE[@]}" down >/dev/null 2>&1 || true; }
trap down EXIT

say "starting CARLA..."
"${COMPOSE[@]}" up -d --wait carla
# Real-time priority for the island, with the container's SYS_NICE and
# nothing else: the runner drops to an unprivileged user, so the island
# cannot raise itself; root in the same container (docker exec -u root keeps
# the container's capability set) moves every island thread to SCHED_FIFO
# once island-up.sh has started it. ASI_ISLAND_RT_PRIO=0 leaves it CFS.
RT_PRIO="${ASI_ISLAND_RT_PRIO:-10}"
prioritize() {
    local pidfile="$ROOT/build/carla-work/state/island.pid" ctr pid i
    for ((i = 0; i < 600; i++)); do
        [ -s "$pidfile" ] && break
        sleep 1
    done
    pid="$(cat "$pidfile" 2>/dev/null)" || return 0
    ctr="$(docker ps -q --filter label=com.docker.compose.project=asi-carla \
        --filter label=com.docker.compose.service=local | head -1)"
    [ -n "$pid" ] && [ -n "$ctr" ] || { say "island RT: no island to prioritize"; return 0; }
    # island-run.sh execs the island under the same pid; wait for that, then
    # a moment for its threads.
    for ((i = 0; i < 30; i++)); do
        [ "$(docker exec "$ctr" cat "/proc/$pid/comm" 2>/dev/null)" != bash ] && break
        sleep 1
    done
    sleep 2
    docker exec -u root "$ctr" chrt -f -a -p "$RT_PRIO" "$pid" &&
        say "island RT: SCHED_FIFO $RT_PRIO on every thread of pid $pid" ||
        say "island RT: chrt failed"
    docker exec -u root "$ctr" bash -c "for t in /proc/$pid/task/*; do chrt -p \${t##*/}; done" \
        >"$ROOT/build/carla-work/state/island-rt.log" 2>&1 || true
}

say "running the integration suite..."
if [ "$RT_PRIO" != 0 ]; then prioritize & fi
set +e
"${COMPOSE[@]}" run --rm local
code=$?
set -e
wait
rm -rf "$ROOT/log/carla" && mkdir -p "$ROOT/log/carla"
cp -r "$ROOT/build/carla-work/artifacts/." "$ROOT/log/carla/" 2>/dev/null || true
cp "$ROOT/build/carla-work/state/"*.jsonl "$ROOT/build/carla-work/state/"*.yaml \
    "$ROOT/build/carla-work/state/island-rt.log" "$ROOT/log/carla/" 2>/dev/null || true
cp -r "$ROOT/build/carla-work/state/island-bag" "$ROOT/log/carla/" 2>/dev/null || true
say "verdict exit $code; artifacts in $ROOT/log/carla"
exit "$code"
