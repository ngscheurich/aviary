# syntax=docker/dockerfile:1
#
# phoenix-base: rootfs image for Phoenix dev sandboxes (microsandbox).
# Single-arch linux/arm64 (macOS Apple Silicon host). See .scratch/plan.md.
#
# Structure:
#   base          — generic: Alpine + mise + OTP-from-source build deps
#   phoenix-base  — base + postgres server + su-exec (this project)
#
# Future flavors (phoenix-api, phoenix-sqlite) are additional stages on `base`.
#
# The image is project-agnostic on purpose: the Erlang/Elixir toolchain is NOT
# baked in. It is installed at sandbox bootstrap time by mise, driven by the
# worktree's own mise.toml (see plan §3/§4).

ARG ALPINE_VERSION=3.23
ARG MISE_VERSION=v2026.9.15

FROM alpine:${ALPINE_VERSION} AS base

ARG MISE_VERSION

# - Runtime essentials + curl/git for kerl/mise downloads
# - ncurses/openssl/zlib: Erlang runtime libs (and -dev: build headers)
# - build-base/autoconf/automake/libtool/m4/linux-headers: mise compiles
#   Erlang from source on musl (no precompiled OTP builds exist for Alpine)
# - perl, tar: OTP build requirements
# - inotify-tools: Phoenix dev server code reloader (file_system port)
RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      git \
      inotify-tools \
      tzdata \
      tar \
      perl \
      ncurses-libs \
      openssl \
      zlib \
      build-base \
      autoconf \
      automake \
      libtool \
      m4 \
      linux-headers \
      ncurses-dev \
      openssl-dev \
      zlib-dev

# mise, musl build — the toolchain manager. Project versions come from the
# guest's mise.toml at bootstrap, never from this image.
RUN curl -fsSL \
      "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-arm64-musl.tar.gz" \
      | tar -xz -C /usr/local/bin --strip-components=2 mise/bin/mise \
    && mise --version

# MISE_DATA_DIR is the mount point of the shared named volume (mise-store),
# so compiled toolchains survive across worktree sandboxes.
# Shims are on PATH so bare `mix`/`erl` resolve to the project's pinned versions.
ENV MISE_DATA_DIR=/root/.local/share/mise \
    PATH=/root/.local/share/mise/shims:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /workspace

# ---------------------------------------------------------------------------
# Flavor: phoenix-base — full Phoenix app with Postgres + asset pipeline
# ---------------------------------------------------------------------------
FROM base AS phoenix-base

# Postgres server + client: the DB lives inside the sandbox (plan req 4).
# su-exec: run postgres as the `postgres` user without a full init system.
# Asset binaries (esbuild/tailwind) are NOT installed here: the mix tasks
# download their own (static / musl) binaries at build time — verified:
#   - @esbuild/linux-arm64 0.25.4: static Go binary, runs on musl
#   - tailwindcss-linux-arm64-musl 4.3.0: upstream musl build, auto-selected
RUN apk add --no-cache postgresql17 postgresql17-client su-exec

WORKDIR /workspace