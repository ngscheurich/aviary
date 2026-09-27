#!/bin/sh
# Build the phoenix-base image and load it into the microsandbox image cache.
#
# Runs on the developer host (macOS + colima + docker CLI + msb).
# Usage: sandbox/build.sh [flavor]   (default: phoenix-base)
#
# Produces sandbox/<flavor>.tar (Docker archive) and runs `msb load` on it.
set -eu

flavor="${1:-phoenix-base}"
here="$(cd "$(dirname "$0")" && pwd)"
tarball="$here/$flavor.tar"

# --- guard: docker CLI present and talking to a builder (colima) -------------
if ! docker info >/dev/null 2>&1; then
  echo "error: docker is unavailable or no builder is running." >&2
  echo "       if colima is installed but stopped: colima start" >&2
  exit 1
fi

echo "==> building $flavor (linux/arm64) -> $tarball"
docker buildx build \
  --platform linux/arm64 \
  --target "$flavor" \
  --tag "$flavor:latest" \
  --output "type=docker,dest=$tarball" \
  "$here"

echo "==> loading $tarball into msb image cache"
if ! command -v msb >/dev/null 2>&1; then
  echo "error: msb not found on PATH (https://docs.microsandbox.dev/cli/overview)" >&2
  exit 1
fi
msb load --input "$tarball"

# Image contract test: boot a throwaway sandbox from the freshly loaded image
# and assert its contents, so a Dockerfile regression can't slip in silently.
echo "==> verifying image ($flavor)"
if ! "$here/check-image.sh" "$flavor"; then
  echo "error: image verification failed — not marking this build as good" >&2
  exit 1
fi

echo "==> done: $flavor:latest loaded and verified. Ready for: bin/sandbox up"