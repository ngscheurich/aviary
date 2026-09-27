#!/bin/sh
# Phase 2 verification (plan §7): with the Aviary sandbox bootstrapped, assert
# the toolchain, postgres, and the artifact-redirect invariants (V1-V4 subset).
#
# Runs on the developer host. Usage: sandbox/check-toolchain.sh [sandbox-name]
set -eu

sbx="${1:-phx-aviary}"

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

# --- V0e: postgres flavor runtime --------------------------------------------
check "postgres user exists"          sh -c 'id postgres'
check "postgres server answers"      sh -c 'psql -h localhost -U postgres -c "select 1" >/dev/null'
check "aviary_dev database exists"   sh -c 'psql -h localhost -U postgres -lqt | cut -d "|" -f1 | grep -qw aviary_dev'

# --- V2x: mise toolchain ------------------------------------------------------
check "erlang 29 via mise"           sh -c 'erl -noshell -eval "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()" | grep -q "^29$"'
check "elixir 1.20.4 via mise"       sh -c 'elixir --version | grep -q 1.20.4'
check "mix runs"                     mix --version
check "toolchain cached in mise-store" sh -c 'test -d /root/.local/share/mise/installs'

# --- V1: build-root redirect -------------------------------------------------
# (setup must have compiled the app first)
check "build_path redirected"        sh -c 'mix eval "IO.puts(Mix.Project.build_path())" | grep -q "^/vm/artifacts/_build/dev"'

# --- V3: asset binaries contained --------------------------------------------
check "esbuild binary under /vm/artifacts"  sh -c 'find /vm/artifacts -type f -name "esbuild-*" | grep -q .'
check "tailwind binary under /vm/artifacts" sh -c 'find /vm/artifacts -type f -name "tailwind-*" | grep -q .'
check "esbuild binary executes"             sh -c 'find /vm/artifacts -type f -name "esbuild-*" -exec {} --version \;'

# --- summary -----------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "==> $failures check(s) FAILED — see output above"
  exit 1
fi
echo "==> all checks passed — $sbx is ready for Phase 3"
exit 0