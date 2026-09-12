#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. It stays visible because you run
# it; the machinery it drives is in .template/.
#
# update-fw.sh — apply the current host list to the running container, now.
#
# The firewall resolves each host once, at container start, and its rules match
# those addresses only. A CDN host answers with other addresses later, so a
# download can fail hours after the start although its host is in domains.conf.
# An edited domains.conf does not reach the container at all, because the image
# was built with a copy of it.
#
# This fixes both: it copies an edited list in and adds the current addresses to
# the live set, flushing nothing. The container already does this by itself every
# few minutes — see .template/fw-watch.sh, which devcontainer.json starts — so
# this is that same tick, on demand, when you would rather not wait for it. The
# form from a shell inside the container:
#     .devcontainer/.template/fw-watch.sh --once
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/.template"

# Pin the compose project name, so `devcontainer exec` finds the container that
# start.sh created. See start.sh for details.
COMPOSE_PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$TEMPLATE_DIR/docker-compose.yml")"
export COMPOSE_PROJECT_NAME

DEVCONTAINER_BIN="$TEMPLATE_DIR/node_modules/.bin/devcontainer"
if [[ ! -x "$DEVCONTAINER_BIN" ]]; then
  echo "ERROR: devcontainer CLI not found at $DEVCONTAINER_BIN. Run ./start.sh first." >&2
  exit 1
fi
EXEC=("$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json")
# Report what exec printed. A missing container is only one reason this fails.
# An old container that still mounts the project at the path the config used
# before an update fails here too, because exec cannot change to the workspace
# folder. Both used to read "not running", which hid the real cause.
if ! PROBE="$("${EXEC[@]}" true 2>&1)"; then
  echo "ERROR: cannot run a command in the dev container. Run ./start.sh to build and start it." >&2
  if [[ -n "$PROBE" ]]; then
    echo "$PROBE" >&2
  fi
  exit 1
fi

exec "${EXEC[@]}" .devcontainer/.template/fw-watch.sh --once
