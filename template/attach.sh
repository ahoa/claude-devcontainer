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

# Both values below are pasted into a shell command that runs in the container
# (see the last line of this script), so both are checked first. Without the
# check, `TMUX_WINDOWS='1; curl … | sh'` ran that command, and a worktree name
# that held a quote closed the quoting and did the same. The installer validates
# the number it writes above, but not what the environment overrides it with.
if [[ ! "$WINDOWS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: TMUX_WINDOWS must be a positive integer (got '$WINDOWS')." >&2
    exit 1
fi

# Pin the compose project name from docker-compose.yml's top-level `name:` so
# `devcontainer exec` looks up the container under the same project name that
# `start.sh`'s `devcontainer up` created it under. See start.sh for details.
COMPOSE_PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$TEMPLATE_DIR/docker-compose.yml")"
export COMPOSE_PROJECT_NAME

# Args (any order):
#   -r | --resume   resume the most recent Claude session in this dir (claude --continue).
#                   Takes effect only when no live tmux session exists yet (e.g. the
#                   first attach after a container restart) — `tmux new-session`
#                   attaches to an existing session and ignores the launch command.
#   <name>          worktree name, forwarded as `claude --worktree <name>`.
RESUME=""
WORKTREE_NAME=""
for arg in "$@"; do
    case "$arg" in
        -r|--resume) RESUME=" --continue" ;;
        *)           WORKTREE_NAME="$arg" ;;
    esac
done
if [[ -n "$WORKTREE_NAME" && ! "$WORKTREE_NAME" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ ]]; then
    echo "ERROR: worktree name may hold letters, digits, '.', '_', '-' and '/' only (got '$WORKTREE_NAME')." >&2
    exit 1
fi

# Fast path — assumes start.sh has already brought the container up and
# installed the devcontainer CLI locally. Errors out cleanly if either is missing.
DEVCONTAINER_BIN="$PROJECT_DIR/node_modules/.bin/devcontainer"
if [[ ! -x "$DEVCONTAINER_BIN" ]]; then
    echo "ERROR: devcontainer CLI not found at $DEVCONTAINER_BIN. Run ./start.sh first." >&2
    exit 1
fi

if ! "$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" true >/dev/null 2>&1; then
    echo "ERROR: dev container is not running. Run ./start.sh to build and start it." >&2
    exit 1
fi

# Re-attach to (or create) the tmux session running Claude. If the session is
# already live this attaches to it as-is — so it picks up exactly where a
# previous, disconnected session left off, including from a different machine.
# On first creation the session gets WINDOWS windows, each with its own Claude;
# `--continue` only makes sense for one instance, so windows 2..N start fresh.
if [[ -n "$WORKTREE_NAME" ]]; then
    SESSION="claude-$WORKTREE_NAME"
    CLAUDE_BASE_CMD="claude --dangerously-skip-permissions --worktree $WORKTREE_NAME"
else
    SESSION="claude"
    CLAUDE_BASE_CMD="claude --dangerously-skip-permissions"
fi
CLAUDE_CMD="$CLAUDE_BASE_CMD$RESUME"

echo "==> Attaching to tmux session '$SESSION' ($WINDOWS window(s))..."
exec "$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" \
    zsh -c "if ! tmux has-session -t '$SESSION' 2>/dev/null; then tmux new-session -d -s '$SESSION' -n claude1 '$CLAUDE_CMD'; for i in \$(seq 2 $WINDOWS); do tmux new-window -d -t '$SESSION:' -n claude\$i '$CLAUDE_BASE_CMD'; done; fi; exec tmux attach -t '$SESSION'"
