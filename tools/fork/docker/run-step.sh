#!/bin/bash
# Run one pipeline phase as a one-off container, from the NAS shell.
#
# Usage: run-step.sh <detect|patch|build|mar|publish|finalize> [target]
#   e.g. run-step.sh detect
#        run-step.sh build linux64
#        run-step.sh build macos-aarch64
#
# Same image, same volumes and same code Woodpecker uses, so this exercises the
# real pipeline without Woodpecker in the way. Useful for bringing the stack up,
# and for re-running a single phase after a failure.

set -euo pipefail

POOL="${FORK_POOL:-/mnt/tank/firefox-fork}"
IMAGE="${FORK_IMAGE:-firefox-fork-builder:latest}"

STEP="${1:-}"
if [ -z "$STEP" ]; then
  echo "usage: run-step.sh <detect|patch|build|mar|publish|finalize> [target]" >&2
  exit 1
fi
shift
TARGET="${1:-}"

# The app container drives the same object directories; two builds in one
# objdir corrupt each other.
if docker ps --format '{{.Names}}' | grep -qx firefox-fork-builder; then
  echo "ERROR: the firefox-fork-builder container is running." >&2
  echo "Stop it first:  sudo docker stop firefox-fork-builder" >&2
  exit 1
fi

mounts=(
  -v "$POOL/src:/src"
  -v "$POOL/state:/state"
  -v "$POOL/obj:/obj"
  -v "$POOL/www:/www"
  -v "$POOL/vs:/vs"
)

env_args=(
  -e FORK_UPDATE_HOST="${FORK_UPDATE_HOST:-firefox-builds.sai.town}"
  -e FORK_UPDATE_SCHEME="${FORK_UPDATE_SCHEME:-https}"
  -e FORK_TARGETS="${FORK_TARGETS:-linux64 win64 macos-aarch64}"
  -e BUILD_JOBS="${BUILD_JOBS:-}"
)

# A build runs for hours, so it is detached: with -it a dropped SSH session
# takes the build with it. Everything else is short and the output is the point.
if [ "$STEP" = "build" ]; then
  name="fork-step-build-${TARGET:-unknown}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run --rm -d --name "$name" \
    "${env_args[@]}" "${mounts[@]}" "$IMAGE" step "$STEP" "$@"
  echo "Started $name in the background."
  echo "Follow it with:  sudo docker logs -f $name"
  echo "Detaching from the logs does not stop it."
else
  docker run --rm -it "${env_args[@]}" "${mounts[@]}" "$IMAGE" step "$STEP" "$@"
fi
