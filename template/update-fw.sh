#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. It stays visible because you run
# it; the machinery it drives is in .template/.
#
# update-fw.sh — resolve the allowed hosts again, inside the running container.
#
# The firewall resolves each host once, at container start, and its rules match
# those addresses only. A CDN host answers with other addresses later, so a
# download can fail hours after the start although its host is in domains.conf.
# This adds the current addresses to the live set and flushes nothing. It is the
# host-side form of this command from a shell inside the container:
#     sudo /usr/local/bin/init-firewall.sh --refresh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/.template"

# Pin the compose project name, so `devcontainer exec` finds the container that
# start.sh created. See start.sh for details.
COMPOSE_PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$TEMPLATE_DIR/docker-compose.yml")"
export COMPOSE_PROJECT_NAME

DEVCONTAINER_BIN="$PROJECT_DIR/node_modules/.bin/devcontainer"
if [[ ! -x "$DEVCONTAINER_BIN" ]]; then
  echo "ERROR: devcontainer CLI not found at $DEVCONTAINER_BIN. Run ./start.sh first." >&2
  exit 1
fi
EXEC=("$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json")
if ! "${EXEC[@]}" true >/dev/null 2>&1; then
  echo "ERROR: dev container is not running. Run ./start.sh to build and start it." >&2
  exit 1
fi

exec "${EXEC[@]}" sudo /usr/local/bin/init-firewall.sh --refresh
