#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. It stays visible because you run
# it; the machinery it drives is in .template/.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Template-owned files nobody should be editing by hand.
TEMPLATE_DIR="$SCRIPT_DIR/.template"

# Number of tmux windows to open on first session creation (each runs its own
# Claude). Set at install time; override at run time with TMUX_WINDOWS=N.
WINDOWS="${TMUX_WINDOWS:-__TMUX_WINDOWS__}"

# Pin the compose project name from docker-compose.yml's top-level `name:`.
# `devcontainer up` and `devcontainer exec` otherwise resolve the project name
# differently for a compose file under .devcontainer/ (exec defaults to
# ${folder}_devcontainer), so exec can't find the container `up` created.
# Exporting COMPOSE_PROJECT_NAME forces up, exec, and plain `docker compose up`
# to agree on a single name.
COMPOSE_PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$TEMPLATE_DIR/docker-compose.yml")"
export COMPOSE_PROJECT_NAME

# Args (any order):
#   -r | --resume   resume the most recent Claude session in this dir (claude --continue).
#                   Useful right after a rebuild: the named config volume keeps the
#                   transcript, so `-r` reloads it instead of starting fresh.
#   <name>          worktree name, forwarded as `claude --worktree <name>`.
RESUME=""
WORKTREE_NAME=""
for arg in "$@"; do
    case "$arg" in
        -r|--resume) RESUME=" --continue" ;;
        *)           WORKTREE_NAME="$arg" ;;
    esac
done

# Install the Dev Containers CLI on demand (locally in the project).
# Official distribution channel is npm — see https://github.com/devcontainers/cli
DEVCONTAINER_BIN="$PROJECT_DIR/node_modules/.bin/devcontainer"
if [[ ! -x "$DEVCONTAINER_BIN" ]]; then
    echo "devcontainer CLI not found — installing @devcontainers/cli locally via npm..."
    if ! command -v npm >/dev/null 2>&1; then
        echo "ERROR: npm is required to install @devcontainers/cli but was not found on PATH." >&2
        echo "Install Node.js (https://nodejs.org) and re-run this script." >&2
        exit 1
    fi
    # --no-save: dev-only tool; installing it here must not rewrite package.json.
    (cd "$PROJECT_DIR" && npm install --no-save @devcontainers/cli)
fi

# Force a rebuild when the image inputs change. `devcontainer up` REUSES an
# existing container as-is — it does not notice an edited Dockerfile (or any
# build input) and will happily re-attach to a stale image. So we hash the build
# inputs ourselves and pass `--remove-existing-container` whenever they differ
# from the last successful run (or on first run, when no marker exists).
BUILD_INPUTS=(
    "$TEMPLATE_DIR/Dockerfile"
    "$TEMPLATE_DIR/docker-compose.yml"
    "$TEMPLATE_DIR/tmux.conf"
    "$TEMPLATE_DIR/init-firewall.sh"
    "$TEMPLATE_DIR/domains-base.conf"
    "$TEMPLATE_DIR/devcontainer.json"
    "$SCRIPT_DIR/tools.sh"
    "$SCRIPT_DIR/domains.conf"
    "$SCRIPT_DIR/docker-compose.override.yml"
)
# sha256sum is GNU coreutils; macOS only started shipping it recently, and shasum is
# what is always there. Either way the hash only has to be stable, not standard.
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum)
else
    SHA_CMD=(shasum -a 256)
fi
BUILD_HASH="$(cat "${BUILD_INPUTS[@]}" 2>/dev/null | "${SHA_CMD[@]}" | cut -d' ' -f1)"
HASH_FILE="$SCRIPT_DIR/.build-hash"

# --config points at the hidden devcontainer.json; without it the CLI would look
# for one at .devcontainer/devcontainer.json, where this template no longer puts it.
UP_ARGS=(up --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" --log-level debug)
if [[ ! -f "$HASH_FILE" || "$(cat "$HASH_FILE" 2>/dev/null)" != "$BUILD_HASH" ]]; then
    echo "==> devcontainer build inputs changed (or first run) — forcing a clean rebuild"
    UP_ARGS+=(--remove-existing-container)
else
    echo "==> devcontainer up (build inputs unchanged — reusing existing container)"
fi

# Tell us about a newer template, but never get in the way: update.sh caches the
# remote SHA for a day, times out fast, and stays silent when offline or when
# already current. Exit 1 just means "update available", so swallow it.
if [[ -x "$SCRIPT_DIR/update.sh" ]]; then
    "$SCRIPT_DIR/update.sh" --check || true
fi

# The Claude config/login volume is shared by every project installed from this
# template (one /login covers all devcontainers). docker-compose.yml declares it
# external, so make sure it exists — `docker volume create` is idempotent.
docker volume create claude-shared >/dev/null

# `devcontainer up` builds the image, starts the compose stack, applies the
# features declared in devcontainer.json, and runs the postStartCommand
# (firewall init).
"$DEVCONTAINER_BIN" "${UP_ARGS[@]}"

# Record the inputs we just built from, so the next run can detect changes.
# Only reached on a successful `up` (set -e aborts earlier on failure).
echo "$BUILD_HASH" > "$HASH_FILE"

# Attach to the running dev container as the configured remoteUser (`dev`) and
# launch Claude inside a tmux session. The session is created on the first run
# and re-attached on later runs, so start.sh and attach.sh share one live
# session. Worktrees get their own session. On first creation the session gets
# WINDOWS windows, each with its own Claude; `--continue` only makes sense for
# one instance, so windows 2..N start fresh.
if [[ -n "$WORKTREE_NAME" ]]; then
    SESSION="claude-$WORKTREE_NAME"
    CLAUDE_BASE_CMD="claude --dangerously-skip-permissions --worktree $WORKTREE_NAME"
else
    SESSION="claude"
    CLAUDE_BASE_CMD="claude --dangerously-skip-permissions"
fi
CLAUDE_CMD="$CLAUDE_BASE_CMD$RESUME"

echo "==> Attaching Claude in tmux session '$SESSION' ($WINDOWS window(s))..."
exec "$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json" \
    zsh -c "if ! tmux has-session -t '$SESSION' 2>/dev/null; then tmux new-session -d -s '$SESSION' -n claude1 '$CLAUDE_CMD'; for i in \$(seq 2 $WINDOWS); do tmux new-window -d -t '$SESSION:' -n claude\$i '$CLAUDE_BASE_CMD'; done; fi; exec tmux attach -t '$SESSION'"
