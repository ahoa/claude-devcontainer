#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# docker-check.sh — runs inside the container. Tells whether dev can reach the
# host Docker daemon, and repairs the one fault it can repair.
#
# With --docker on, the docker-outside-of-docker feature mounts the host socket
# at /var/run/docker-host.sock. Its entrypoint, /usr/local/share/docker-init.sh,
# starts a socat proxy on /var/run/docker.sock that dev owns. Nothing supervises
# that proxy. When it is gone, every docker command fails with "permission
# denied". Before this check, the failure showed only where a command needed
# Docker, in the middle of an E2E run for example.
#
# start.sh and attach.sh run this and go on when it fails: a session without
# Docker still has uses. loop.sh refuses instead, because every story of a
# night's run would stop at the same place.
#
#   exit 0   Docker answers, or this install has no Docker (--docker off)
#   exit 1   Docker does not answer, and stderr says why
set -uo pipefail

# The feature installs the docker CLI. No CLI means --docker off: nothing to check.
command -v docker >/dev/null 2>&1 || exit 0

docker info >/dev/null 2>&1 && exit 0

# The entrypoint is idempotent: it leaves a proxy that still runs alone and starts
# one that is gone. It then execs its arguments, so `true` ends it. dev owns the
# script, and the script takes sudo for its root steps itself.
INIT=/usr/local/share/docker-init.sh
if [[ -x "$INIT" ]]; then
  echo "==> Docker does not answer, starting the socket proxy again..." >&2
  "$INIT" true >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 && exit 0
fi

SOCK=/var/run/docker.sock
echo "WARNING: dev cannot use Docker in this container." >&2
if mountpoint -q "$SOCK" 2>/dev/null; then
  # The container came from a template that mounted the socket here as well.
  # The entrypoint cannot remove a mountpoint, so its proxy never starts.
  echo "  $SOCK is a bind mount of the host socket, which the feature's proxy cannot replace." >&2
  echo "  Run ./update.sh, then ./start.sh: the new compose file recreates the container." >&2
elif [[ ! -S "$SOCK" ]]; then
  echo "  $SOCK does not exist." >&2
else
  echo "  $(ls -l "$SOCK")" >&2
fi
echo "  The proxy log is /tmp/vscr-docker-from-docker.log." >&2
exit 1
