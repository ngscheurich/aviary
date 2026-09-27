#!/bin/sh
# Phase 1 verification (plan §7): boot an empty sandbox from the built image
# and assert its contents. Deterministic: assertions + exit codes, no humans.
#
# Runs on the developer host. Usage: sandbox/check-image.sh [flavor]
set -eu

flavor="${1:-phoenix-base}"
image="$flavor:latest"
sbx="image-check-$$"   # unique name so concurrent runs don't collide

cleanup() {
  msb rm "$sbx" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

failures=0
check() { # check <label> <command...>
  label="$1"; shift
  if msb exec "$sbx" -- "$@" >/dev/null 2>&1; then
    echo "PASS  $label"
  else
    echo "FAIL  $label"
    failures=$((failures + 1))
  fi
}

echo "==> creating throwaway sandbox '$sbx' from $image"
msb rm "$sbx" >/dev/null 2>&1 || true
msb create "$image" --name "$sbx"

# --- V0a: base platform ------------------------------------------------------
check "alpine os-release"          sh -c 'grep -q "ID=alpine" /etc/os-release'
check "mise on PATH and runs"      mise --version
check "mise data dir in env"       sh -c 'test "$MISE_DATA_DIR" = /root/.local/share/mise'
check "mise shims on PATH"         sh -c 'echo "$PATH" | grep -q /root/.local/share/mise/shims'
# NOTE: there is no separate "musl build" assertion: mise's musl distribution
# is statically linked, so its version string never says "musl" and ldd shows
# no musl interpreter. Successful execution on a musl guest IS the proof
# (the image only runs musl binaries; a glibc-linked mise would crash).

# --- V0b: OTP build toolchain ------------------------------------------------
check "gcc (OTP build)"            gcc --version
check "make (OTP build)"           make --version
check "perl (OTP build)"           perl -v
check "autoconf/automake/libtool"  sh -c 'autoconf --version && automake --version && libtoolize --version'

# --- V0c: phoenix-base flavor -------------------------------------------------
check "postgres server binary"    postgres --version
check "postgres client binary"    psql --version
check "initdb present"            sh -c 'command -v initdb'
check "pg_ctl present"            sh -c 'command -v pg_ctl'
check "su-exec present"           sh -c 'command -v su-exec'

# --- V0d: dev-server runtime --------------------------------------------------
check "inotifywait (code reloader)" sh -c 'command -v inotifywait'

# --- summary -----------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "==> $failures check(s) FAILED — image incomplete; see output above"
  exit 1
fi
echo "==> all checks passed — $image is ready for Phase 2"
exit 0