#!/bin/sh
# Phase 3 verification suite (plan §8): deterministic assertions with exit
# codes — no editors, browsers, or human judgment.
#
# Runs on the developer host. Invoked by `sandbox verify`; may also be run
# directly: sandbox/verify.sh <sandbox-name> <host-port> <worktree-path> <wt-name>
#
# V1-V4  in-VM: build-root redirect, deps un-redirected, asset binaries, tests
# V5-V7  host↔guest coexistence: ELF-leak, _build non-interference, concurrent
#        compiles
# V8     HTTP gate: forwarded server responds; code reloader reacts to host
#        edits; markup asserted, template restored
#
# Failing checks print an excerpt of the captured output — nothing is
# silently discarded.
set -eu

sbx="${1:?sandbox name required}"
port="${2:?host port required}"
root="${3:?worktree path required}"
wtname="${4:?worktree name required}"

url="http://127.0.0.1:$port/"
tpl="$root/lib/aviary_web/controllers/page_html/home.html.heex"
tpl_bak="$tpl.sandbox-verify-bak"

tmp="$(mktemp -d)"
guest_out="$tmp/guest.out"
host_out="$tmp/host.out"

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
show() { # <caption> <file> [lines] — print first lines of captured output
  max="${3:-12}"
  if [ -s "$2" ]; then
    echo "      $1"
    sed -n "1,${max}p" "$2" | sed 's/^/        | /'
  fi
}

guest() { msb exec "$sbx" -- "$@" >"$guest_out" 2>&1; }
guest_ok() { # <label> <command...>
  label="$1"; shift
  if guest "$@"; then
    pass "$label"
  else
    fail "$label"
    show "guest output:" "$guest_out"
  fi
}

cleanup() {
  if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp" "$root/.sandbox-verify-marker" "$tpl_bak"
}
trap cleanup EXIT INT TERM

echo "==> verifying $sbx (worktree: $root, port: $port)"

# --- V1: Mix build-root redirect ---------------------------------------------
guest_ok "V1  build_path redirected to /vm/artifacts" \
  sh -c 'mix eval "IO.puts(Mix.Project.build_path())" | grep -q "^/vm/artifacts/_build/dev"'

# --- V2: deps deliberately un-redirected --------------------------------------
guest_ok "V2  deps_path still inside the worktree" \
  sh -c "mix eval 'IO.puts(Mix.Project.deps_path())' | grep -q \"^/workspace/$wtname/deps$\""

# --- V4: mix test inside the VM ----------------------------------------------
guest_ok "V4  mix test (in-VM postgres)" \
  sh -c 'db-start && mix test'

# --- V5/V6: full VM build must not leak artifacts into the worktree -----------
marker="$root/.sandbox-verify-marker"
touch "$marker"

if [ -d "$root/_build" ]; then
  build_state_before="$(find "$root/_build" -type f -exec shasum {} + | shasum | cut -d' ' -f1)"
else
  build_state_before="absent"
fi

if guest sh -c 'mix do clean, compile, assets.build'; then
  pass "V5  full VM build ran (clean, compile, assets.build)"
else
  fail "V5  full VM build ran (clean, compile, assets.build)"
  show "guest output:" "$guest_out"
fi

elf="$(find "$root" -newer "$marker" -type f -exec file {} + 2>/dev/null | grep -c ELF || true)"
if [ "$elf" -eq 0 ]; then
  pass "V6a no ELF (linux) artifact leaked into the worktree"
else
  fail "V6a no ELF (linux) artifact leaked into the worktree ($elf found)"
fi

if [ "$build_state_before" = "absent" ]; then
  if [ ! -e "$root/_build" ]; then
    pass "V6b host _build untouched (still absent)"
  else
    fail "V6b host _build untouched (VM created it)"
  fi
else
  build_state_after="$(find "$root/_build" -type f -exec shasum {} + | shasum | cut -d' ' -f1)"
  if [ "$build_state_before" = "$build_state_after" ]; then
    pass "V6b host _build untouched (hash identical)"
  else
    fail "V6b host _build untouched (hash changed)"
  fi
fi

rm -f "$marker"

# --- V3: asset binaries contained under /vm/artifacts -------------------------
# Runs AFTER the V5 full build on purpose: the binaries are installed by the
# mix asset tasks on first use, so a fresh sandbox that never ran `setup`
# would vacuously fail this check before anything built them. (V3c never
# fails vacuously with an empty find — `-exec` on zero matches exits 0 — but
# V3a/V3b would.)
guest_ok "V3a esbuild binary under /vm/artifacts" \
  sh -c 'test -n "$(find /vm/artifacts -type f -name "esbuild-*")"'
guest_ok "V3b tailwind binary under /vm/artifacts" \
  sh -c 'test -n "$(find /vm/artifacts -type f -name "tailwind-*")"'
guest_ok "V3c esbuild binary executes" \
  sh -c 'find /vm/artifacts -type f -name "esbuild-*" -exec {} --version \;'

# --- V7: concurrent host + VM compiles ---------------------------------------
if command -v mix >/dev/null 2>&1 && [ -d "$root/deps/phoenix" ]; then
  # Host-side compile only — this suite never mutates the host. If the host
  # is not bootstrapped for this project, we skip with instructions rather
  # than installing hex or fetching deps on the user's behalf.
  (cd "$root" && mix compile) >"$host_out" 2>&1 &
  host_pid=$!
  vm_rc=0
  guest sh -c 'mix compile' || vm_rc=1
  host_rc=0
  wait "$host_pid" || host_rc=1
  if [ "$vm_rc" -eq 0 ] && [ "$host_rc" -eq 0 ]; then
    pass "V7  concurrent host+VM compiles both succeeded"
  else
    fail "V7  concurrent host+VM compiles both succeeded (vm=$vm_rc host=$host_rc)"
    [ "$vm_rc" -ne 0 ] && show "vm compile output:" "$guest_out"
    [ "$host_rc" -ne 0 ] && show "host compile output:" "$host_out"
  fi
  elf="$(find "$root" -type f -exec file {} + 2>/dev/null | grep -c ELF || true)"
  if [ "$elf" -eq 0 ]; then
    pass "V7  no ELF artifact in worktree after concurrent compiles"
  else
    fail "V7  no ELF artifact in worktree after concurrent compiles ($elf found)"
  fi
else
  echo "SKIP  V7  host not bootstrapped for this project (concurrent-compile check not run)"
  echo "      to enable it, run once on the host:"
  echo "        mix local.hex --force"
  echo "        mix local.rebar --force"
  echo "        mix deps.get"
fi

# --- V8: HTTP gate + code reloader -------------------------------------------
# Start the server as a FOREGROUND exec, backgrounded on the HOST side: a
# guest-side `nohup server &` gets reaped when the exec session returns
# (observed: empty log, no process). Keeping the exec session open for the
# duration of the checks is the reliable pattern.
wait_for_url() { # <timeout-secs>
  waited=0
  while [ "$waited" -lt "$1" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

server_pid=""
if ! curl -fsS "$url" >/dev/null 2>&1; then
  msb start "$sbx" >/dev/null 2>&1 || true
  # The exec session is kept open (host-side backgrounding) and the server's
  # output is redirected to a guest-side FILE: `msb exec` buffers captured
  # output until the command completes, but the file is written live by
  # Phoenix, so failures are always diagnosable via exec tail.
  msb exec "$sbx" -- sh -c 'server >/tmp/phx-server.log 2>&1' &
  server_pid=$!
fi

if wait_for_url 180 && curl -fsS "$url" | grep -q "Phoenix Framework"; then
  pass "V8a server responds on forwarded port with expected markup"
else
  fail "V8a server responds on forwarded port with expected markup"
  msb exec "$sbx" -- sh -c 'tail -80 /tmp/phx-server.log 2>&1' \
    >"$guest_out" 2>&1 || true
  show "server log (guest /tmp/phx-server.log, last 80 lines):" "$guest_out" 60
  if grep -q "StorageNotCreatedError\|invalid_catalog_name" "$guest_out" 2>/dev/null; then
    echo "      => the dev database was never created in this sandbox; run:" >&2
    echo "           bin/sandbox setup" >&2
  fi
  msb exec "$sbx" -- \
    sh -c 'ps w 2>/dev/null | grep -E "beam|mix|phx|esbuild|tailwind" | grep -v grep || echo NO-PROCESSES' \
    >"$guest_out" 2>&1 || true
  show "guest processes (beam/mix/watchers):" "$guest_out"
  msb exec "$sbx" -- \
    sh -c 'netstat -tln 2>/dev/null | grep -E ":(4000|5432)" || echo NO-LISTENERS' \
    >"$guest_out" 2>&1 || true
  show "guest listeners (4000/5432):" "$guest_out"
  msb exec "$sbx" -- \
    sh -c 'curl -fsS -o /dev/null http://127.0.0.1:4000/ && echo GUEST_OK || echo GUEST_FAIL' \
    >"$guest_out" 2>&1 || true
  show "guest-side reachability (127.0.0.1:4000):" "$guest_out"
  echo "      a 503 on the guest port is the endpoint answering with a" >&2
  echo "      broken boot state — the request IS reaching Phoenix; read the" >&2
  echo "      log above (e.g. StorageNotCreatedError => bin/sandbox setup)." >&2
  echo "      GUEST_OK + host FAIL would instead mean a binding issue" >&2
  echo "      (PHX_BIND_ALL)." >&2
fi

if [ -f "$tpl" ]; then
  cp "$tpl" "$tpl_bak"
  marker_txt="<!-- sandbox-verify-$$ -->"
  printf '\n%s\n' "$marker_txt" >> "$tpl"
  served=1
  waited=0
  while [ "$waited" -lt 30 ]; do
    if curl -fsS "$url" 2>/dev/null | grep -q "sandbox-verify-$$"; then served=0; break; fi
    sleep 2
    waited=$((waited + 2))
  done
  cp "$tpl_bak" "$tpl"
  gone=1
  waited=0
  while [ "$waited" -lt 30 ]; do
    if ! curl -fsS "$url" 2>/dev/null | grep -q "sandbox-verify-$$"; then gone=0; break; fi
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$served" -eq 0 ] && [ "$gone" -eq 0 ]; then
    pass "V8b code reloader picks up host edits (and reverted cleanly)"
  else
    fail "V8b code reloader picks up host edits (and reverted cleanly)"
  fi
else
  echo "SKIP  V8b template not found at $tpl"
fi

# --- summary -------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "==> $failures check(s) FAILED"
  exit 1
fi
echo "==> all checks passed"
exit 0