# Self-contained release image for Ymer Node. Multi-stage: the builder produces a
# mix release with ERTS bundled, and the runtime is a slim Debian with no Erlang,
# no Elixir and no Node — the host needs only Docker.
#
# Nothing about any one company's network belongs in this image. It is a public
# artifact: it fetches from public hex and trusts the distribution's own CA
# bundle. A network that intercepts TLS is a property of the machine doing the
# build, not of the node, so the trust for it belongs on that machine.

ARG ELIXIR_VERSION=1.20.1
ARG OTP_VERSION=28.4.1
ARG DEBIAN_VERSION=bookworm-20260610-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# build-essential: exqlite compiles a C NIF. ca-certificates is already in the
# base image; it is listed so the dependency is explicit rather than inherited.
RUN apt-get update -y && apt-get install -y build-essential ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Single-mapped JIT code. Under emulation — an amd64 build on an Apple-Silicon
# host — OTP 28's dual-mapped W^X JIT memory is not translated correctly and the
# BEAM dies at startup with {failed_to_start_child,user,nouser}, which would kill
# every `RUN mix` layer below. This MUST precede the first of them, so that the
# very first BEAM boot already carries it. Harmless on native builds; builder
# stage only, never shipped.
ENV ERL_FLAGS="+JMsingle true"

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, for layer caching. mix.lock is committed, so this fetches
# the exact resolved versions — a reproducible build.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# priv carries the vendored sqlite-vec loadables, one per architecture. The repo
# picks the matching one at boot and refuses to start if it is absent.
COPY priv priv
COPY lib lib

RUN mix compile

COPY config/runtime.exs config/

# The release overlays — `bin/ymer-node`, the operator's CLI. Overlays are
# copied over the built release by `mix release`, so this has to be here before
# it runs, and without it the image would carry a node no operator can reach
# from a shell.
COPY rel rel

RUN mix release

# ── Runtime image ───────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

# libstdc++6 and openssl are what the bundled ERTS and the exqlite NIF link
# against; ca-certificates is the Mozilla bundle the release's TLS reads. Do not
# trim any of them as "already in the base image".
RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app
ENV MIX_ENV="prod"

# Create the mount point and give it to `nobody` BEFORE the volume is attached.
# Docker creates a missing mount point root-owned, and the release then runs as
# `nobody` and cannot mkdir /data/db — the container dies at boot on :eacces with
# a fresh named volume. Creating it here means the image works with a plain
# `docker run -v`, not only under compose's `user:` override.
RUN mkdir -p /data && chown nobody /data

# runtime.exs is a Config.Reader provider, so the release writes the computed
# config and reboots the VM at EVERY boot. The default location is under /app,
# which the compose file's `user:` override does not own — it is a host UID, not
# `nobody`. /tmp is mode 1777 and writable by any UID, so the reboot succeeds
# whatever UID is injected.
ENV RELEASE_TMP=/tmp

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/ymer_node ./

# This RUN is the only thing that creates the bind marker, and its path must stay
# byte-identical to the one config/runtime.exs checks — no test gates their
# agreement, and a drift makes the container serve nobody. It is written outside
# /app so that copying the release directory out of this image cannot carry the
# widening along. Why the marker is the channel at all, and what it costs, is
# maintained in YmerNode.Mcp's "Loopback is the security model" section; the term
# itself is defined in docs/glossary.md.
RUN mkdir -p /etc/ymer-node && touch /etc/ymer-node/bind-all-interfaces

# The git revision this image was built from, passed as a build argument and
# carried into the runtime environment so the node can say what code it runs.
# Stamped here, after the release has been copied in, so that changing it
# reuses every layer above: the COPY from the builder stays cached across a
# revision change. Blank when the builder could not name one — no git, or no
# work tree — and `config/runtime.exs` then leaves the wire version bare.
ARG YMER_NODE_REVISION=""
ENV YMER_NODE_REVISION=${YMER_NODE_REVISION}

USER nobody

CMD ["/app/bin/ymer_node", "start"]
