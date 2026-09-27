# Phoenix microsandbox tooling

Isolate a Phoenix app (esbuild + Postgres pipeline) in a [microsandbox]
microVM — one VM per git worktree, with its own database, its own build
artifacts, and a toolchain driven by the project's [mise.toml]. Designed for
a macOS host that keeps working in parallel: the worktree stays portable
(sources flow both ways) and every platform-specific artifact the VM produces
is kept out of it.

## Requirements (host)

- [microsandbox] (`msb`); check with `msb doctor`
- colima (or Docker Desktop) providing the `docker` CLI
- Apple Silicon (the image is `linux/arm64`) or Linux with KVM

## Quickstart

```sh
sandbox/build.sh                # build + msb load the phoenix-base image
bin/sandbox up                   # create-or-start this worktree's VM
bin/sandbox setup                # mix setup inside the VM (deps, DB, assets)
bin/sandbox server               # postgres + mix phx.server, http://127.0.0.1:<port>
bin/sandbox verify               # deterministic verification suite (V1–V8)
bin/sandbox verify-worktrees     # multi-worktree suite (V9–V11)
```

The host keeps working as usual: `mix phx.server`, ElixirLS/Expert, tests,
`mix compile` — all run against the same worktree without ever seeing the
VM's build artifacts.

## Commands (`bin/sandbox`)

| Command | What it does |
|---|---|
| `build [flavor]` | Build the OCI image and load it into msb's cache |
| `up` | Create-or-start the VM; bootstraps on first creation |
| `setup` | `mix setup` in the VM (idempotent) |
| `server` | Postgres + `mix phx.server` in the VM (foreground) |
| `test` / `precommit` | Mix tasks in the VM (with its own postgres) |
| `exec CMD...` / `shell` | Arbitrary command / interactive shell in the VM |
| `status` / `logs` / `stop` / `rm` | Lifecycle |
| `port` / `port --set N` | Show/pin this worktree's forwarded host port |
| `verify` | Per-worktree suite: V1–V8 |
| `verify-worktrees` | Multi-worktree suite: V9–V11 |
| `worktrees` | Overview: all worktrees, their VMs, ports, states |

## Where things live

| Location | What | Shared? | Survives |
|---|---|---|---|
| worktree (bind mount) | portable sources; `deps/` (source), `priv/static/assets/` | host ↔ VM | — |
| `/vm/artifacts` (owned volume) | the VM's `_build/`, esbuild/tailwind binaries, kerl staging | no (per worktree) | stop/start |
| `/var/lib/postgresql/data` (owned volume) | this VM's database | no (per worktree) | stop/start |
| `mise-store` (named volume) | compiled toolchains, one dir per version | across all VMs | `msb volume rm` |
| `hex-cache` (named volume) | uncompiled package tarballs | across all VMs | `msb volume rm` |

Key env (set in `sandbox/sandbox.yaml`):

- `MIX_BUILD_ROOT=/vm/artifacts/_build` — the host/VM non-interference trick.
  Compiled BEAM/NIF artifacts and the asset binaries (they install next to
  the build root) never touch the worktree, so the host's own `_build` stays
  macOS-pure. Same technique the official language server uses for its own
  engine cache.
- `PHX_BIND_ALL=1` — published ports forward to the guest's network
  interface, not guest-loopback; `config/dev.exs` binds `{0,0,0,0}` when
  this is set (host default remains loopback; safe in the VM since only
  published ports accept inbound).
- `MIX_XDG=1`, `MISE_YES=1`, `KERL_BASE_DIR`/`KERL_CONFIGURE_OPTIONS` for
  headless OTP builds inside the artifacts volume.

## Verification

Every check is an assertion with an exit code — no editors, browsers, or
human judgment. `sandbox/verify.sh` (V1–V8) covers the artifact-redirect
invariants (build path, deps path, asset binaries), in-VM tests, the
ELF-leak check (no Linux binary ever appears in the worktree), host `_build`
non-interference, concurrent host+VM compiles, and the HTTP/code-reload
gate. `sandbox/verify-worktrees.sh` (V9–V11) covers sandbox-per-worktree
naming, all-pairs database isolation, and port distinctness. The suite never
mutates the host; if the host isn't bootstrapped for the project, V7 skips
with the exact commands to run.

## Troubleshooting

- **V8a fails with HTTP 503** — the request *is* reaching Phoenix; a 503 is
  the endpoint answering with a broken boot state. Read the guest log:
  `bin/sandbox exec -- tail -80 /tmp/phx-server.log`.
  `StorageNotCreatedError` / `database "..." does not exist` means the dev
  DB was never created: run `bin/sandbox setup`.
- **First `up`/`bootstrap` is slow** — Erlang compiles from source on musl
  (~10–15 min, once per version, cached in `mise-store` for all VMs).
- **`msb doctor` complains** — no KVM / virtualization; the VM needs it.
- **Port confusion** — the registry is `~/.config/phoenix-sandbox/ports`;
  allocation starts at 4001 (4000 stays free for your host server). A
  pre-existing sandbox's published port can be pinned with
  `bin/sandbox port --set N`.
- **Asset binaries crash with `ERR_DLOPEN_FAILED`** — never mark guest
  `/tmp` noexec: the tailwind CLI (Bun) extracts native modules to `$TMPDIR`
  and `dlopen`s them.
- **`msb exec ... -- test`** — the name `test` collides with `/usr/bin/test`
  and the shell builtin; use `sh -c 'db-start && mix test'` instead (the
  wrapper does this for you).
- **Host LSP state** — dirs like `.expert/` appear in the worktree from the
  host side; gitignore them so they don't leak into commits.

[microsandbox]: https://docs.microsandbox.dev/getting-started/introduction
[mise.toml]: https://mise.jdx.dev/
