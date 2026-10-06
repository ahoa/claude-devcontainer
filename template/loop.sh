#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. It stays visible because you run
# it; the machinery it drives is in .template/.
#
# loop.sh — start the ca plugin's loop runner in the container, unattended.
#
#   ./loop.sh            bring the container up and start one loop run
#   ./loop.sh --attach   watch the running loop (tmux session "loop")
#
# The division of labour is the same as for the plugin flag: this repo knows how
# Claude starts inside the container and nothing about what a run does; the ca
# plugin owns hooks/lib/loop-runner.sh and knows nothing about the container. All
# this script passes across that line is environment.
#
# Meant to be driven by a systemd user timer — see the README's Loop section,
# including why the unit must be user-level and not system-level.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Template-owned files nobody should be editing by hand.
TEMPLATE_DIR="$SCRIPT_DIR/.template"

# Pin the compose project name from docker-compose.yml's top-level `name:` so
# `devcontainer up` and `devcontainer exec` look the container up under the same
# project name that start.sh created it under. See start.sh for details.
COMPOSE_PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$TEMPLATE_DIR/docker-compose.yml")"
export COMPOSE_PROJECT_NAME
# The same base image tag as start.sh gives the build. `up` below builds nothing
# when the container is there, but compose resolves the build arg either way.
CLAUDE_DEVBASE_IMAGE="$("$TEMPLATE_DIR/build-hash.sh" --base)"
export CLAUDE_DEVBASE_IMAGE

# No install-on-demand here, unlike start.sh. Everything this script does at night
# has to be something it can also do at 03:00 with nobody watching, and reaching
# npm is not that.
DEVCONTAINER_BIN="$TEMPLATE_DIR/node_modules/.bin/devcontainer"
if [[ ! -x "$DEVCONTAINER_BIN" ]]; then
    echo "ERROR: devcontainer CLI not found at $DEVCONTAINER_BIN. Run ./start.sh first." >&2
    exit 1
fi

DEVCONTAINER_ARGS=(--workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json")

# Watching the loop is its own flag, and its own tmux session. attach.sh goes to
# the session "claude", which is the interactive one; the loop must not land in
# it, or a night's run and a person's session fight over the same window.
if [[ "${1:-}" == "--attach" ]]; then
    exec "$DEVCONTAINER_BIN" exec "${DEVCONTAINER_ARGS[@]}" tmux attach -t loop
fi
# --attach is the only argument there is. A mistyped one must not fall through to
# a night's work: start.sh can read a stray word as a worktree name and be wrong
# cheaply, this one would start Claude on the wrong intent entirely.
if [[ $# -gt 0 ]]; then
    echo "ERROR: unknown argument '$1'. Usage: loop.sh [--attach]" >&2
    exit 1
fi

# How many stories one run may take. Pasted into a shell command that runs in the
# container (see the last line), so it is checked first — the same reason start.sh
# checks TMUX_WINDOWS. A systemd unit's `Environment=` is as much an untrusted
# source here as a shell is.
MAX_STORIES="${MAX_STORIES:-5}"
if [[ ! "$MAX_STORIES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_STORIES must be a positive integer (got '$MAX_STORIES')." >&2
    exit 1
fi

# A changed build input means the image start.sh last built is not the image this
# project now describes. start.sh rebuilds at that point; this script refuses.
# A rebuild is minutes of network and a chance to fail, and a failure here happens
# at night with nobody to see it — so the loop never rebuilds, it only reports.
if ! "$TEMPLATE_DIR/build-hash.sh" --check; then
    echo "ERROR: build inputs changed, run ./start.sh first." >&2
    exit 1
fi

# Idempotent: reuses the container start.sh created, and starts it again if it was
# stopped. Quiet, because the interesting output of a loop run is in its own log.
"$DEVCONTAINER_BIN" up "${DEVCONTAINER_ARGS[@]}" >/dev/null

# The ca plugin: the flag comes from the host, where the plugin is installed, and
# docker-compose.yml mounts that directory into the container at the same absolute
# path. An interactive session may start without the plugin — ca-plugin-flag.sh
# warns and returns nothing. A loop run may not: without the plugin there is no
# /ca:develop to run.
CA_FLAG="$(bash "$TEMPLATE_DIR/ca-plugin-flag.sh")"
if [[ -z "$CA_FLAG" ]]; then
    echo "ERROR: the ca plugin is not installed on the host. The loop does not start without it." >&2
    echo "       Install it on the host: claude plugin install claude-agents@codeborne" >&2
    exit 1
fi
CA_DIR="${CA_FLAG#* --plugin-dir }"

# The runner is the plugin's file, so an older plugin version simply does not have
# it. Checked on the host, where the path is the same one the container sees.
RUNNER="$CA_DIR/hooks/lib/loop-runner.sh"
if [[ ! -f "$RUNNER" ]]; then
    echo "ERROR: ca plugin too old, needs hooks/lib/loop-runner.sh." >&2
    echo "       Update it on the host: claude plugin update claude-agents@codeborne" >&2
    exit 1
fi
if [[ ! -x "$RUNNER" ]]; then
    echo "ERROR: $RUNNER is not executable. The mount is read-only, so fix it on the host." >&2
    exit 1
fi

# What tmux runs. The env assignments are the whole interface to the runner. This
# string is single-quoted where it is used below, so the two values holding a
# space are double-quoted here.
RUNNER_CMD="CA_PLUGIN_DIR=$CA_DIR MAX_STORIES=$MAX_STORIES"
RUNNER_CMD+=" GIT_AUTHOR_NAME=\"Codeborne Loop\" GIT_COMMITTER_NAME=\"Codeborne Loop\""
RUNNER_CMD+=" GIT_AUTHOR_EMAIL=loop@codeborne.com GIT_COMMITTER_EMAIL=loop@codeborne.com"
# tee, not a plain redirect: the session shows the run while it happens and the
# log keeps it after the session is gone. A run ends with its tmux session.
RUNNER_CMD+=" $RUNNER 2>&1 | tee -a .loop-state/loop.log"

# Detached, so this script returns at once and the systemd unit can be a oneshot.
# `devcontainer exec` needs no TTY for any of this and lands in the workspace
# folder, which is the repo root.
#
# One run at a time: a timer that fires while the previous run is still going
# would otherwise put two Claudes on one working tree.
exec "$DEVCONTAINER_BIN" exec "${DEVCONTAINER_ARGS[@]}" zsh -c "
    if tmux has-session -t loop 2>/dev/null; then
        echo 'loop already running'
        exit 0
    fi
    mkdir -p .loop-state
    tmux new-session -d -s loop '$RUNNER_CMD'
    echo 'loop started'
"
