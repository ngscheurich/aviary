# Plan: Isolating Phoenix apps in microsandbox microVMs

Companion to `goal.md`. Grounded in the current microsandbox docs (fetched from
docs.microsandbox.dev) and the Aviary repo (Phoenix 1.8 + Bandit, esbuild +
tailwind pipeline, `mise.toml` pinning `elixir 1.20.4-otp-29` / `erlang 29.1.1`).

## 0. Context and constraints discovered

- **This workspace is itself a microsandbox** (hostname `msb-*`, Alpine 3.23,
  aarch64, no `/dev/kvm`). Nested microVMs are not possible from in here —
  end-to-end runs must happen on the developer's host (macOS Apple Silicon or a
  Linux box with KVM). We can author everything here; validation of actual VM
  boots happens on the host.
- `msb` is not installed in this workspace. The plan includes installing it on
  the dev host (`curl -fsSL https://install.microsandbox.dev | sh`, then
  `msb doctor`).
- microsandbox consumes **standard OCI images** as root filesystems (Docker
  Hub/GHCR pull, or `msb load` from a Docker/OCI archive — no registry needed).
- Sandboxes are **named, persistent VMs**: `create` → boots; `stop`/`start`
  preserves the writable root and owned volumes; `rm` destroys them.
- Bind mounts make host↔guest file sharing live; `network.ports` forwards host
  ports (loopback by default) into the guest; scripts can be installed into the
  guest `PATH` via config; command exec uses a dedicated host↔guest channel (no
  SSH, works even with networking disabled).

## 1. Architecture overview

```
developer host
├── sandbox/Dockerfile ──build──▶ OCI archive ──msb load──▶ msb image cache
│   (generic "phoenix-base" Alpine image; no project deps baked in)
│
├── sandbox/sandbox.yaml.tpl ──render──▶ per-worktree sandbox config
│   (image, cpus/mem, ports, mounts, volumes, scripts, env)
│
└── bin/sandbox  (wrapper CLI: up, setup, server, test, exec, stop, rm, …)
    │ derives sandbox name from the git worktree path
    ▼
microsandbox VM  "phx-<worktree-name>"      [one per git worktree]
├── rootfs: phoenix-base image (Alpine + mise + apk build deps)
├── bind mount:  <worktree>:/workspace/<name>  (rw — sources only; artifacts redirected)
├── owned volume:/vm/artifacts              (VM's _build/ + esbuild/tailwind binaries)
├── owned volume:/var/lib/postgresql/data     (private to this VM, persists stop/start)
├── named volume: mise-store:/root/.local/share/mise   (shared: toolchain cache)
├── named volume: hex-cache:/root/.cache/hex           (shared: package tarballs)
├── tmpfs: /tmp
├── ports: 127.0.0.1:<host-port>:4000 (allocated per worktree: 4000, 4001, …)
└── guest processes: postgres + (optionally) mix phx.server
```

Design principle: **the image is generic** (Alpine + mise + Postgres + build
toolchain), and **all project-specific state lives in the worktree bind mount
and the per-worktree sandbox**. That is what makes "one VM per worktree, with
drifting deps and private data" fall out naturally.

**Host-collaboration principle (macOS host):** the worktree bind mount is the
shared source plane, and it stays fully portable. Every platform-specific
artifact the VM produces is redirected into guest-owned storage so it never
touches the host worktree. Mechanisms (both verified against Elixir 1.20.4):

- `MIX_BUILD_ROOT=/vm/artifacts/_build` — Mix writes all compiled artifacts
  (`_build/dev/...`) there instead of `<worktree>/_build`.
- The esbuild/tailwind binaries downloaded by their mix tasks install to
  `Path.dirname(Mix.Project.build_path())` — i.e. `/vm/artifacts/esbuild-*`
  and `/vm/artifacts/tailwind-*`, automatically contained by the same redirect.
- `MIX_DEPS_PATH` also exists, but we **deliberly do not redirect `deps/`**:
  it is unpacked source (portable, host-shareable), and Aviary's asset pipeline
  hard-codes relative `deps/` references (`@plugin "../../deps/daisyui/..."`
  in app.css, `NODE_PATH: ../deps` in config.exs) that would break under a
  redirect. `deps/` is a hex/github source tree, so sharing it host↔guest is
  safe; a host-side `mix` can even populate it and the VM will use it as-is.

## 2. Requirement → mechanism mapping

| # | Requirement | Mechanism |
|---|---|---|
| 1 | OCI image as rootfs | Dockerfile → OCI archive → `msb load` (or push to a registry if the team prefers) |
| 2 | Alpine, minimal deps | `alpine:3.22` base; only: apk build toolchain needed to compile OTP on musl, Postgres server, runtime libs, `mise` musl binary. No `apk add elixir/erlang/node` |
| 3 | mise-provided toolchain | `mise` is installed in the image; the guest bootstrap script runs `mise install` inside the worktree (reads the project's `mise.toml`). Exact versions per project; coexisting versions in the shared mise store |
| 4 | DB isolated in the VM | `postgresql` runs inside the same VM; data dir on an **owned volume**; `DATABASE_URL` injected by the wrapper (guest-only `localhost`); host DB never touched |
| 5 | Worktrees get own VMs | Sandbox name = `phx-$(basename <worktree-dir>)`; worktree bind-mounted rw for **sources** (generators/migrations write portable text to the host) while build artifacts are redirected to per-sandbox storage (`MIX_BUILD_ROOT`); per-sandbox owned volumes for PG data and `_build`; per-worktree host port allocation |
| 6 | Cache dependencies between runs | Three tiers, see §5: msb image cache, shared named volumes (mise store, hex tarball cache), per-sandbox owned volume for compiled artifacts; optional disk snapshots of warm sandboxes |

## 3. The image (`sandbox/Dockerfile`)

Base `alpine:3.22` (or 3.23 to match the current workspace), **single-arch
`linux/arm64`** (macOS Apple Silicon host; x86_64 deferred until needed).
Contents:

- `ca-certificates`, `curl`, `git`, `bash`, `tzdata`
- `mise` binary (musl build, arch-appropriate) installed to
  `/usr/local/bin/mise`
- OTP build dependencies (mise/asdf-erlang builds Erlang from source on musl):
  `build-base autoconf automake libtool m4 linux-headers ncurses-dev openssl-dev
  zlib-dev` (+ runtime `openssl ncurses-libs zlib`); this is the known slow step
  (~10–15 min per Erlang version) — mitigated by the shared mise volume (§5)
- `postgresql17` + `postgresql17-client`, `su-exec`, `openrc`-free process
  control (we start postgres from a config script, not an init system)
- Non-root `dev` user to match bind-mount file ownership expectations
- A small `/usr/local/bin/db-init` + `db-start` helper (postgres data-dir init
  and launch; Alpine's `pg_ctl` under `su-exec`)

**Flavor architecture** (decided: generic image now, but project setups will
diverge later — API-only apps without an asset pipeline, sqlite instead of
postgres, etc.). The Dockerfile is therefore structured as a shared **base
stage** (Alpine + mise + OTP build toolchain + runtime libs) plus **flavors**
built as targets from it:

- `phoenix-base` — base + postgres17 + asset-pipeline support (this project)
- future: `phoenix-api` (base only, no postgres / asset tooling),
  `phoenix-sqlite` (base + exqlite compile deps, no postgres server)

The base stage carries ~95% of the image; flavors add only what they need, so
"install only the necessary dependencies" (req 2) holds per flavor. The
wrapper picks the flavor per project — auto-detect (`:postgrex` vs
`:ecto_sqlite3` in `mix.exs` deps, `assets/` presence), overridable in a
per-project config file — and the flavor name doubles as the OCI tag and the
sandbox.yaml image.

Explicitly **not** installed: elixir, erlang, node, npm (requirement 3).
esbuild/tailwind binaries are fetched by the mix tasks into the worktree's
`priv/` — see risk R1.

Build & load (host-side, no registry required):

```
docker build --platform linux/arm64 --target phoenix-base -o phoenix-base.tar sandbox/
msb load phoenix-base.tar
```

(`podman`/`buildah` work identically; the wrapper's `build` subcommand takes a
flavor argument.)

## 4. Sandbox configuration (`sandbox/sandbox.yaml.tpl` → rendered YAML)

The wrapper renders this per worktree and passes it with `--conf`. Key fields:

```yaml
image: phoenix-base:latest
cpus: 2
memory: "4G"
workdir: "/workspace/${WORKTREE_NAME}"
user: "dev"
hostname: "${WORKTREE_NAME}"
env:
  DATABASE_URL: "ecto://postgres:postgres@localhost/dev"
  MIX_ENV: "dev"
  # keep every linux-flavored build artifact out of the (macOS-host) worktree:
  MIX_BUILD_ROOT: "/vm/artifacts/_build"
mounts:
  - "${WORKTREE_PATH}:/workspace/${WORKTREE_NAME}:rw"   # portable sources only
  - { owned: /vm/artifacts }        # VM's _build/ + esbuild/tailwind binaries
  - { named: mise-store, target: /root/.local/share/mise, create: ensure-exists }
  - { named: hex-cache,  target: /root/.cache/hex,         create: ensure-exists }
  - { owned: /var/lib/postgresql/data }
  - { tmpfs: { size: "512M" }, target: /tmp }
network:
  policy: public   # hex.pm, github (heroicons/daisyui deps), registry access
  ports: ["${HOST_PORT}:4000"]
scripts:
  bootstrap: "mise install && db-init"          # idempotent toolchain + DB init
  setup: "mise exec -- mix setup"
  server: "db-start && mise exec -- mix phx.server"
  test: "db-start && mise exec -- mix test"
```

Notes / decisions baked in:

- Bind mount stays **rw** because source writes from the VM are legitimate
  and portable (`mix phx.gen.*` writes `.ex/.heex` files the host editor and
  git should see). Host↔guest portability is protected by redirecting the
  platform-specific writes, not by making the mount read-only:
  - `MIX_BUILD_ROOT` moves all of `_build` (the user's host `mix` runs —
  dev server, tests, etc. — keep using `<worktree>/_build` for their own
  macOS builds; no collision). Note the precedent: this is the same
  isolation technique the official language server uses — [Expert]
  (https://github.com/expert-lsp/expert) compiles projects with its own
  versioned `MIX_BUILD_PATH` pointing at `.expert/build` for exactly this
  reason (its engine toolchain differs from the developer's shell toolchain
  and sharing `_build` would corrupt both).
  - esbuild/tailwind binaries land next to `build_path/` → inside the same
    redirect. This is the *only* place the mix asset tasks put binaries.
  - Compiled asset output (`priv/static/assets/`) is portable JS/CSS; it
    deliberately writes through to the worktree (host-visible, gitignored,
    byte-identical whether host or VM produces it). If churn proves annoying,
    a nested owned-volume mount on that path is a config-only fallback.
- Named volume mounts use `create: ensure-exists` so the first `up` provisions
  them; they are intentionally **shared across worktree VMs** (see §5).
- `deps/` is intentionally **not** redirected (`MIX_DEPS_PATH` exists but is
  unused): it's portable source, and Aviary's CSS/`NODE_PATH` reference
  `deps/` by relative path. Hex tarballs in the shared cache are also pure
  source; **compiled** dependency artifacts always land in the per-sandbox
  `/vm/artifacts` owned volume, so dependency-tree drift between worktrees
  cannot collide (see §5).
- PG data lives on an **owned volume**: private to this sandbox, survives
  `stop`/`start`, dies with `rm`. No data sharing between worktrees (req 5),
  no host DB usage (req 4).

## 5. Caching strategy (req 6)

| Tier | What | Where | Shared? | Lifetime |
|---|---|---|---|---|
| 1 | Alpine base + apk layers | msb image cache (`~/.microsandbox/cache`) | yes, content-addressed | until `msb image prune` |
| 2a | mise toolchains (per Erlang/Elixir version) | named volume `mise-store` | **yes, across worktree VMs** — mise stores each version in its own directory, so concurrent drift is safe | until `msb volume rm` |
| 2b | hex **package tarballs only** (download cache) | named volume `hex-cache` | **yes, across worktree VMs** — the hex cache is a content-addressed store of *uncompiled* source archives keyed by package+version+checksum; compilation happens later into `_build`. Dependency-tree drift between worktrees can therefore never collide here | until `msb volume rm` |
| 3a | unpacked dep **sources** | inside the worktree bind mount (`deps/`) | no (per-worktree by nature); portable, host-shareable | with the worktree |
| 3b | **compiled** deps + app build (`_build/*`) + downloaded esbuild/tailwind binaries | per-sandbox owned volume `/vm/artifacts` | **no** — this is where platform-flavored artifacts live, so it must be per-worktree; survives stop/start | dies with the sandbox |
| 4 | warm "boot" snapshots (optional, phase 4) | `msb snap create` after bootstrap | per snapshot | restores fork instantly |

Clarification on "compiled dependencies": compilation output never touches the
hex cache or `~/.mix` — Mix compiles every dep into
`_build/<env>/lib/<dep>/`, which the `MIX_BUILD_ROOT` redirect places in the
per-sandbox owned volume. `~/.mix` (mix archives like phx_new, rebar escripts)
is tiny and OTP-version-sensitive, so it stays in the guest rootfs (not
shared) to avoid any drift edge cases.

Erlang-on-musl compilation is the expensive step; tier 2a ensures it happens
once per Erlang version, ever, across all worktrees on the machine. Tier 3b is
*not* shared by design: sharing `_build` across worktrees with drifted toolchains
would reuse BEAM files compiled under a different OTP. If cross-recreate caching
ever matters, a per-worktree *named* volume (`build-cache-<name>`) is the
config-only escape hatch, at the cost of that OTP-drift caveat.

## 6. Wrapper CLI (`bin/sandbox`, plain POSIX shell)

Plain shell, zero host dependencies beyond `msb` and an OCI builder (decided).
Two usage modes are both first-class (decided):

1. **VM-server mode**: `sandbox server` runs postgres + `mix phx.server` in
   the VM, reachable at `http://127.0.0.1:<host-port>`.
2. **Runner mode**: `sandbox exec|shell|test|precommit` run arbitrary mix
   tasks in the VM, with or without the server running.

Both coexist with **host-macOS execution**: the developer can simultaneously
run their own `mix phx.server` on the host (conventionally port 4000) — port
allocation skips host-bound ports, so VM servers land on 4001+.

Subcommands (all operate on the sandbox derived from the current worktree):

- `sandbox build` — build the OCI image + `msb load`
- `sandbox up` — `connect_or_create` semantics: create if missing, start if
  stopped, attach if running; run `bootstrap` script on fresh creation
- `sandbox setup` — run `mise install` + `mix setup` inside the VM
- `sandbox server` — start postgres + `mix phx.server`, stream logs; print the
  forwarded URL (`http://127.0.0.1:<host-port>`)
- `sandbox test` / `sandbox precommit` — run inside the VM (DB included)
- `sandbox exec [-- CMD...]`, `sandbox shell` — ad-hoc commands
- `sandbox status` / `logs` / `stop` / `rm` / `port`
- `sandbox worktrees` — list detected worktrees, their sandbox names, ports,
  and running state

Naming: `phx-$(basename "$(git rev-parse --show-toplevel)")` (sanitized). Port
allocation: lowest free port from 4000 upward, persisted in a per-worktree
`.scratch/sandbox.json` (gitignored) so restarts reuse it.

## 7. Implementation phases (each gated by validation)

- **Phase 0 — host prerequisites & spike** (on the dev host)
  - Install `msb`; run `msb doctor` (KVM / Apple Silicon check). ✅ done
  - OCI builder: **colima — ✅ already installed and running** on the host.
    The wrapper standardizes on the `docker` CLI interface (which colima
    provides) and BuildKit `-o` archive output. It checks for a working
    `docker` (and can start colima if stopped) before building.
- **Phase 1 — image**
  - ✅ `sandbox/Dockerfile` authored (base stage + `phoenix-base` flavor),
    pinned: alpine 3.23, mise v2026.9.15 (musl arm64), postgresql17 17.11.
  - ✅ `sandbox/build.sh` (buildx → Docker archive → `msb load`) and
    `sandbox/check-image.sh` (V0a–V0d assertion suite, throwaway sandbox).
  - ✅ Pre-build spike, executed on an Alpine 3.23 aarch64 musl host (this
    workspace) with hard evidence:
    - `@esbuild/linux-arm64` 0.25.4 binary: **static Go binary, runs on musl**
      (`esbuild --version` → 0.25.4; `ldd` → not dynamic)
    - `tailwindcss-linux-arm64-musl` 4.3.0: **upstream musl build exists and
      runs**; the mix `tailwind` package auto-selects the `-musl` suffix on
      v4+ when OTP reports a musl target (`maybe_add_abi_suffix/2`)
    - mise musl arm64 binary runs; `mise ls-remote` confirms `erlang 29.1.1`
      and `elixir 1.20.4-otp-29` are resolvable
  - ⏳ Remaining (host-side, needs colima + msb): run `sandbox/build.sh` and
    `sandbox/check-image.sh` on the Mac, then green-light Phase 2.
- **Phase 2 — toolchain inside the VM** (validates req 2, 3, and risk R2)
  - ✅ `sandbox/sandbox.yaml` authored (env-substituted config: mounts, env,
    ports, bootstrap/db-start/setup/server/test scripts). Owned mounts pass
    via CLI flags (`--mount-owned`) since they have no YAML form. Scripts use
    `$VAR` (no braces) because msb substitutes `${VAR}` across the whole file.
  - ✅ `sandbox/check-toolchain.sh` (V0e/V1–V3 subset assertions).
    **Retired in Phase 5**: fully subsumed by verify.sh's V1–V4; deleted.
  - Discovered: Aviary dev/test configs already point at
    `localhost:postgres:postgres` with DB names `aviary_dev`/`aviary_test`,
    so no `DATABASE_URL` env is needed — in-VM postgres with trust auth
    matches the app config as-is. Dev endpoint binds `{127,0,0,1}`: whether
    msb port-forwarding reaches a guest-loopback listener is a Phase 3
    experiment (fallback: env-gated `ip: {0,0,0,0}` in dev.exs).
  - ⏳ Host runbook: create sandbox, run `bootstrap` (Erlang-from-source,
    first run ~10–15 min), run `setup`, then `check-toolchain.sh`.
- **Phase 3 — full app, one worktree** (validates req 1, 2, 3, 4, 6) — ✅ **COMPLETE, all V1–V8 green.** Includes the env-gated `PHX_BIND_ALL` dev.exs change (forwarding experiment resolved: `msb modify phx-aviary --env PHX_BIND_ALL=1` applies live to future commands).
  - ✅ `bin/sandbox` wrapper authored (POSIX sh): up/setup/server/test/
    precommit/exec/shell/status/logs/stop/rm/port/verify/worktrees; sandbox
    name `phx-<worktree-basename>` (path-hash disambiguation on collisions);
    machine-global port registry at `~/.config/phoenix-sandbox/ports`,
    allocation from 4001 up (4000 reserved for the host server).
  - ✅ `sandbox/verify.sh` (V1–V8) authored; wired as `sandbox verify`.
  - ✅ CLI facts confirmed: `msb exec` auto-starts/stops stopped sandboxes
    (so setup/test work without `up`); `msb ls -q` names-only;
    `msb start` for persistent resume.
  - ⏳ Host runbook: `sandbox up` (attaches to existing phx-aviary),
    `sandbox verify`. V8a doubles as the loopback-vs-0.0.0.0 forwarding
    experiment: if the guest serves on 127.0.0.1:4000 but the host curl
    fails, apply the env-gated `PHX_BIND_ALL` change in dev.exs and re-run.
  - Findings so far (all fixed or diagnosed):
    - ✅ V1–V6 green (redirect, deps, asset binaries, tests, ELF-leak,
      _build non-interference) after two wrapper bugs: `basename`+`tr` tail
      dash in name derivation, and `set -e` killing `port_for` on a
      missing registry file.
    - `test` script name collides with `/usr/bin/test` and the shell
      builtin under `msb exec -- test` — removed from sandbox.yaml;
      wrapper/verify inline `db-start && mix test` instead.
    - Port allocation must match the sandbox's actual published port
      (`--set` added; auto-probe of `msb inspect` json pending).
    - Guest-side `nohup server &` under `msb exec` is reaped when the exec
      session returns (empty log, no listener) — V8 now keeps the exec
      session open host-side instead.
    - The host needs its own one-time bootstrap (hex/rebar/deps.get).
      Decision: the suite must NOT mutate the host — V7 checks
      preconditions (host `mix` + fetched `deps/`) and SKIPs with the exact
      manual commands when the host isn't bootstrapped. The wrapper's
      principle going forward: host-side changes are always explicit.
    - ✅ **V8a forwarding experiment resolved**: `GUEST_OK` + host FAIL —
      msb published ports forward to the guest's network interface, not
      guest-loopback. Applied the env-gated `PHX_BIND_ALL` fallback in
      config/dev.exs (host default stays loopback) + `PHX_BIND_ALL: "1"`
      in sandbox.yaml env; existing sandboxes update via
      `msb modify <name> --env PHX_BIND_ALL=1` (live, future commands).
      V7 concurrent compiles passed once the host was bootstrapped.
  - **Doc note**: host-LSP state dirs like `.expert/` will appear in the
    worktree from the host side; the README should list them as recommended
    gitignore additions so they don't leak into commits from either side.
- **Phase 4 — worktree fan-out + polish** (validates req 5) — ✅ **COMPLETE, V9–V11 green across two worktrees**, with both per-worktree suites (V1–V8) green for phx-aviary and phx-aviary-phase4. Fixed a self-inflicted bug found in the process: an echo hint in verify-worktrees.sh wrapped 'bin/sandbox verify' in backticks inside double quotes, so the shell executed the suite as command substitution and spliced its output into the hint (harmless, accidentally proved the root sandbox green, but unintended nested execution).
  - ✅ `sandbox/verify-worktrees.sh` (V9–V11) authored; wired as
    `sandbox verify-worktrees`.
  - First phase4-worktree verify found two suite bugs (fixed):
    - V3 ran before the build that installs the asset binaries — a sandbox
      whose `setup` never completed failed V3a/b vacuously. V3 now runs
      after the V5 full build; the suite no longer depends on `setup`.
    - `msb exec` buffers captured output until the command completes — the
      V8 server's output was invisible during its boot. The server now
      redirects to a guest-side file (`/tmp/phx-server.log`, written live)
      while the exec session stays open host-side; wait raised to 180s;
      failures print the log tail + `netstat` listener table + guest curl
      probe. A **503 on the guest port means the forwarding relay answered
      with the backend down** — noted in the suite's hints.
  - **✅ phase4 V8a root cause found**: the dev database `aviary_dev` was
    never created in that sandbox (its aborted `setup` never reached
    `ecto.setup` — consistent with the missing asset binaries earlier).
    `Phoenix.Ecto.CheckRepoStatus` — a plug phoenix_ecto installs in the
    dev endpoint that runs on the first request — raised
    `StorageNotCreatedError`, which also answers the "why does phx.server
    run migrations" question (it doesn't; the plug does). Server processes
    (beam + watchers) were healthy and Bandit was listening; the 503 was
    Phoenix's own response. Verify now prints a targeted `bin/sandbox
    setup` hint on this error.
- **Phase 5 — docs & ergonomics** — ✅ `sandbox/README.md` authored (usage,
  commands, storage model, env rationale, verification overview,
  troubleshooting). Final housekeeping: `.worktrees/` + `/.expert/` gitignored
  (an accidental `.worktrees/aviary-phase4` gitlink in 78715ad needs
  `git rm --cached` on the host), last commit of the suite fixes, and
  `bin/sandbox precommit` as the dogfooded final gate. Then the plan is
  complete.

## 8. Deterministic verification suite (`sandbox verify`)

A single subcommand of the wrapper, runnable any time after `sandbox up`.
Every check is an assertion with an exit code — no editors, no browsers, no
human judgment. Portable to CI (Linux + KVM) unchanged.

**In-VM assertions** (via `msb exec`, also enforced by `bootstrap` so a broken
redirect can never silently degrade):

| # | Assertion |
|---|---|
| V1 | `Mix.Project.build_path()` starts with `/vm/artifacts/_build` (redirect active) |
| V2 | `Mix.Project.deps_path()` equals `/workspace/<name>/deps` (deps deliberately un-redirected) |
| V3 | esbuild + tailwind `bin_path()` exist and live under `/vm/artifacts` |
| V4 | `mix test` exits 0 against the in-VM postgres |

**Host-side assertions:**

| # | Assertion |
|---|---|
| V5 | **ELF-leak check**: `touch marker` → full VM build (`setup`, `assets.build`) → `find . -newer marker -type f -exec file {} + | grep -c ELF` is 0. On the macOS host any ELF file is a Linux artifact, so this mechanically proves "no platform-flavored write reached the worktree" |
| V6 | **`_build` non-interference**: hash `_build/dev/lib/**` before the V5 build and after → identical (VM never mutates the host build tree) |
| V7 | **Concurrent builds**: launch host `mix compile` and VM `mix compile` at the same time; both exit 0; V5 still holds (V6 does not apply — the host build legitimately writes its own `_build` during this check) |
| V8 | **HTTP gate**: `curl 127.0.0.1:<host-port>` → 200 with expected markup; `sed`-edit a template on the host, curl again → updated content served (code reloader works through the bind mount, no browser needed) |

**Multi-worktree assertions** (Phase 4):

| # | Assertion |
|---|---|
| V9 | With two worktree VMs running: insert a sentinel row via psql in VM A → `count(*) = 0` in VM B's DB (owned-volume isolation) |
| V10 | Both VMs serve their own ports concurrently (V8 against both) |
| V11 | `msb ls` shows exactly one sandbox per `git worktree list` entry, named deterministically |

## 9. Risks and mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | esbuild/tailwind binaries fail on musl | **✅ Resolved pre-build** with direct evidence (see Phase 1 spike): esbuild is a static Go binary and runs on musl; tailwind ships an official `-musl` build that the mix package auto-selects. Fallbacks kept on file: `apk add esbuild` exists in Alpine community (0.25.12) if ever needed; `config :esbuild/:tailwind, path:` override remains possible. `gcompat` deliberately NOT in the image |
| R2 | Erlang-from-source on musl is slow (~10–15 min) | Accept once per version thanks to shared `mise-store` volume; document; optional disk snapshot tier-4 path |
| R3 | Bind-mount perf (virtiofs) slows source reads | Compile I/O goes to the owned volume (native guest ext4, fast); only source reads + artifact writes cross virtiofs. If still painful, move `priv/static/assets` to a nested owned volume | Phase 3 measurements |
| R4 | Port exhaustion / collisions with many worktrees | deterministic allocation + persisted port map; `sandbox port` reports it |
| R5 | Bind-mount uid/gid mismatch (host user vs guest `dev`) | Use mount `uid=,gid=` fallback identity or run guest as root; pick in Phase 1–2 |
| R6 | No KVM on some hosts (e.g. this workspace) | `msb doctor` gate in `sandbox up`; clear error message |
| R7 | OTP 29 build failures on musl (rare OpenSSL version quirks) | Pin alpine version known-good for OTP 29 (3.22/3.23), track upstream asdf-erlang patches; worst case document required apk pins |
| R8 | Mix env-var redirect regression (env vars exist in Elixir ≥ 1.14/1.20; verified `MIX_BUILD_ROOT`, `MIX_DEPS_PATH`, `MIX_BUILD_PATH` in v1.20.4 source) | Pin documented minimum Elixir; verification V1 fails fast (exit 1) at `bootstrap` time if `Mix.Project.build_path()` isn't under `/vm/artifacts` |
| R9 | Asset pipeline paths assume `deps/` beside the project (daisyui `@plugin "../../deps/..."`, `NODE_PATH=../deps`) | Consequence of the design, not a risk: `deps/` is *not* redirected; documented as a constraint for anyone who later wants `MIX_DEPS_PATH` |
| R10 | Bun-based CLIs (tailwindcss ≥ v4) extract native modules to `$TMPDIR` and `dlopen()` them — **fired in Phase 2**: `noexec` on the /tmp tmpfs caused `ERR_DLOPEN_FAILED: Operation not permitted` | **✅ Fixed**: /tmp tmpfs mounted without `noexec` (`sandbox/sandbox.yaml`). Note for future flavors: never mark guest `/tmp` noexec in this image |

## 10. Decisions (from review)

1. **Arch**: `linux/arm64` only; x86_64 deferred (add a buildx platform when
   needed).
2. **Distribution**: local OCI archive via `msb load`; no registry.
3. **Image genericity**: generic flavor-based image (§3 flavor architecture).
   Later project setups (API-only, sqlite) become new flavors on the same
   base — not a fork of the design.
4. **Execution model**: both VM-server and runner modes are first-class, and
   host-macOS execution keeps working concurrently (§6).
5. **Wrapper**: plain POSIX shell; no host Elixir required.

## 11. Non-goals (for this iteration)

- microsandbox cloud deployment (config already leans on local-only features:
  owned volumes, disk-image mounts would not translate; revisit later)
- Docker-in-Docker, multi-service compose-style stacks inside the VM
- x86_64 / multi-arch image builds (flavor architecture in §3 makes this a
  buildx flag away, when needed)
- `phoenix-api` / `phoenix-sqlite` flavors (architecture anticipates them;
  not built in this iteration)
- CI integration (can follow once the local flow is proven; `sandbox verify`
  is already CI-runnable on a Linux + KVM host)