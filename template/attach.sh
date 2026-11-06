#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. It stays visible because you run
# it; the machinery it drives is in .template/.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/.template"

# Number of tmux windows to open on first session creation (each runs its own
# Claude). Set at install time; override at run time with TMUX_WINDOWS=N.
WINDOWS="${TMUX_WINDOWS:-__TMUX_WINDOWS__}"

# The arguments and their checks are in launch.sh, shared with start.sh.
# shellcheck source=template/launch.sh
source "$TEMPLATE_DIR/launch.sh"
parse_args attach "$@"
check_project_dir

# Pin the compose project name from docker-compose.yml's top-level `name:` so
# `devcontainer exec` looks up the container under the same project name that
# `start.sh`'s `devcontainer up` created it under. See start.sh for details.
COMPOSE_PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$TEMPLATE_DIR/docker-compose.yml")"
export COMPOSE_PROJECT_NAME

# Fast path — assumes start.sh has already brought the container up and
# installed the devcontainer CLI under .template/. Errors out cleanly if either is
# missing.
DEVCONTAINER_BIN="$TEMPLATE_DIR/node_modules/.bin/devcontainer"
if [[ ! -x "$DEVCONTAINER_BIN" ]]; then
    echo "ERROR: devcontainer CLI not found at $DEVCONTAINER_BIN. Run ./start.sh first." >&2
    exit 1
fi

# The devcontainer CLI reads every compose file in devcontainer.json, and only
# start.sh writes this one. See node-modules.sh.
"$TEMPLATE_DIR/node-modules.sh" stub

# Report what exec printed. A missing container is only one reason this fails.
# An old container that still mounts the project at the path the config used
# before an update fails here too, because exec cannot change to the workspace
# folder. Both used to read "not running", which hid the real cause.
if ! PROBE="$("$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" true 2>&1)"; then
    echo "ERROR: cannot run a command in the dev container. Run ./start.sh to build and start it." >&2
    if [[ -n "$PROBE" ]]; then
        echo "$PROBE" >&2
    fi
    exit 1
fi

# Can dev reach the host Docker daemon? A warning, not a stop, see start.sh.
# Nothing supervises the socket proxy, so this is where a proxy that died since
# the last start gets started again.
"$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" \
    .devcontainer/.template/docker-check.sh || true

# The ca plugin: the container's own install, or else the host plugin through
# the flag, see start.sh.
if "$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" \
    .devcontainer/.template/ca-plugin.sh installed >/dev/null 2>&1; then
    CA_FLAG=""
else
    CA_FLAG="$(bash "$TEMPLATE_DIR/ca-plugin-flag.sh")"
fi

launch_claude "Attaching to"
