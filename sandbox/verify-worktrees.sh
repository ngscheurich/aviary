#!/bin/sh
# Phase 4 verification (plan §8): multi-worktree assertions V9-V11.
#
# V11  one sandbox per git worktree, no strays
# V9   per-VM database isolation (all-pairs sentinel databases)
# V10  distinct forwarded ports per sandbox (registry uniqueness)
#
# Runs on the developer host, from any worktree of this repo:
#   sandbox/verify-worktrees.sh      (or: bin/sandbox verify-worktrees)
set -eu

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git worktree" >&2
  exit 1
}

ports_file="${PHX_SANDBOX_PORTS:-$HOME/.config/phoenix-sandbox/ports}"

# Sandbox names as bin/sandbox derives them. (The collision case adds a
# -<hash> suffix; here we match prefixes so suffixed names still map to
# their worktree.)
worktree_names() {
  git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "phx-$(printf '%s' "$(basename "$p")" | tr -c 'a-zA-Z0-9-' '-')"
  done
}

msb_phx_names() { msb ls -q 2>/dev/null | grep '^phx-' || true; }

db_name_for() { printf 'sandbox_verify_%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_' '_')"; }

echo "==> multi-worktree verification"

# --- V11: one sandbox per worktree, no strays ----------------------------------
v11_failed=0
for expected in $(worktree_names); do
  found=0
  for actual in $(msb_phx_names); do
    case "$actual" in "$expected" | "$expected"-*) found=1; break ;; esac
  done
  if [ "$found" -ne 1 ]; then
    echo "      missing: $expected (run: bin/sandbox up in that worktree)" >&2
    v11_failed=1
  fi
done
for actual in $(msb_phx_names); do
  matched=0
  for expected in $(worktree_names); do
    case "$actual" in "$expected" | "$expected"-*) matched=1; break ;; esac
  done
  if [ "$matched" -ne 1 ]; then
    echo "      stray: $actual has no git worktree (msb rm $actual?)" >&2
    v11_failed=1
  fi
done
if [ "$v11_failed" -eq 0 ]; then
  pass "V11 one sandbox per git worktree, no strays"
else
  fail "V11 one sandbox per git worktree, no strays"
fi

# --- V9: per-VM database isolation (all pairs) ---------------------------------
# Give every sandbox its own sentinel database, then assert that no other
# sandbox can see it. Uses psql's database listing (no app tables touched).
v9_failed=0
for name in $(msb_phx_names); do
  dbn="$(db_name_for "$name")"
  msb exec "$name" -- \
    sh -c "db-start && psql -h localhost -U postgres -c 'create database $dbn' >/dev/null 2>&1 || true" \
    >/dev/null 2>&1 || true
done
for name in $(msb_phx_names); do
  dbn="$(db_name_for "$name")"
  for other in $(msb_phx_names); do
    [ "$other" = "$name" ] && continue
    if msb exec "$other" -- \
         sh -c "psql -h localhost -U postgres -lqt | cut -d '|' -f1 | grep -qw $dbn" \
         >/dev/null 2>&1; then
      echo "      $dbn (from $name) is visible inside $other" >&2
      v9_failed=1
    fi
  done
done
# tidy up the sentinel databases
for name in $(msb_phx_names); do
  dbn="$(db_name_for "$name")"
  msb exec "$name" -- \
    sh -c "psql -h localhost -U postgres -c 'drop database if exists $dbn' >/dev/null 2>&1" \
    >/dev/null 2>&1 || true
done
if [ "$v9_failed" -eq 0 ]; then
  pass "V9 database isolation holds across all sandbox pairs"
else
  fail "V9 database isolation holds across all sandbox pairs"
fi

# --- V10: distinct forwarded ports per sandbox --------------------------------
v10_failed=0
if [ -f "$ports_file" ]; then
  dups="$(awk '$1 ~ /^phx-/ { print $2 }' "$ports_file" | sort | uniq -d)"
  if [ -n "$dups" ]; then
    echo "      duplicate registered ports:" >&2
    printf '        %s\n' $dups >&2
    v10_failed=1
  fi
fi
if [ "$v10_failed" -eq 0 ]; then
  pass "V10 every sandbox has a distinct forwarded port"
else
  fail "V10 every sandbox has a distinct forwarded port"
fi
echo "      (V10's concurrency half — both servers serving simultaneously —"
echo "       is exercised by running 'bin/sandbox verify' in two worktrees"
echo "       at the same time.)"

# --- summary -------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "==> $failures check(s) FAILED"
  exit 1
fi
echo "==> all checks passed"
exit 0