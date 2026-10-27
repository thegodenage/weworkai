#!/bin/sh
# The docker reviewer's dind sidecar starts alongside this container; wait until its
# daemon answers so the agent's first `docker` command doesn't fail.
if [ -n "$DOCKER_HOST" ]; then
  waited=0
  until docker info >/dev/null 2>&1; do
    waited=$((waited + 1))
    if [ "$waited" -ge 60 ]; then
      echo "the docker sidecar did not start within 60s" >&2
      exit 1
    fi
    sleep 1
  done
fi
exec "$@"
