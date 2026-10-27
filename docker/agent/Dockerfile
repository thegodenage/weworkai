# The container every weworkai agent runs in (bin/claude_bridge builds and tags it).
# Add a toolchain by adding it here: the bridge tags images by this folder's content, so
# the next run after an edit rebuilds the image.

# The docker CLI and its compose/buildx plugins, for the docker reviewer (qa), which talks
# to its own per-run docker:dind sidecar, never to the host's Docker.
FROM docker:27.5.1-cli AS docker-cli

FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.309
# The bridge passes the host user's ids on Linux so files the agent writes stay the
# user's; Docker Desktop (macOS) maps ownership itself and keeps the defaults.
ARG AGENT_UID=1000
ARG AGENT_GID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep curl ca-certificates build-essential python3 python3-venv python3-pip \
      jq less procps unzip openssh-client \
 && rm -rf /var/lib/apt/lists/*

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force

# Bind-mounted repositories belong to the host user, not to `agent`.
RUN git config --system --add safe.directory '*'

# node:22 ships a `node` user with uid 1000; `agent` takes its place.
RUN userdel --remove node \
 && groupadd --non-unique --gid "${AGENT_GID}" agent \
 && useradd --non-unique --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --shell /bin/bash agent \
 && mkdir -p /home/agent/.claude \
 && chown -R agent:agent /home/agent

COPY entrypoint.sh /usr/local/bin/cph-agent-entrypoint

USER agent
# Everything claude keeps (conversations, settings) sits in the one folder the bridge
# mounts its named volume on, so `--resume` works across runs.
ENV HOME=/home/agent \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

ENTRYPOINT ["cph-agent-entrypoint"]
