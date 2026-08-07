#!/usr/bin/env bash
#
# install.sh — install a project-agnostic Claude devcontainer setup into a
# target project's .devcontainer/ directory.
#
# Prompts for a project name (used for the Docker image / compose project /
# named volumes) and verifies it does not collide with anything Docker already
# knows about, then asks how many tmux windows (each running its own Claude) the
# session should open. Copies the template files, substituting those choices.
#
# Works both from a checkout and standalone (curl … | bash): when there is no
# template/ next to the script, the template is downloaded from GitHub into a
# temp dir. Prompts are read from /dev/tty, so piping the script into bash still
# lets you answer them.
#
set -euo pipefail

# Falls back to $PWD when there is no script file to locate (curl … | bash).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$PWD}")" 2>/dev/null && pwd || echo "$PWD")"
TEMPLATE_DIR="$SCRIPT_DIR/template"

# Where to fetch the template from when it is not available locally.
REPO_URL="${CLAUDE_DEVCONTAINER_REPO:-https://github.com/ahoa/claude-devcontainer}"
REPO_REF="${CLAUDE_DEVCONTAINER_REF:-main}"

# Files copied verbatim into <target>/.devcontainer/.
TEMPLATE_FILES=(
    Dockerfile
    devcontainer.json
    devcontainer-lock.json
    docker-compose.yml
    init-firewall.sh
    allowed-domains.conf
    tmux.conf
    start.sh
    attach.sh
)
# Files that get the executable bit.
EXECUTABLE_FILES=(start.sh attach.sh init-firewall.sh)

usage() {
    cat <<'EOF'
Usage: install.sh [options] [target-dir]

Installs the Claude devcontainer template into <target-dir>/.devcontainer/.
target-dir defaults to the current directory.

Options:
  --name NAME       Project name (lowercase [a-z0-9][a-z0-9_-]*). Prompted if omitted.
  --windows N       Number of tmux windows to open (each runs a Claude). Default 1.
  --force           Overwrite an existing .devcontainer/ and ignore name conflicts.
  -h, --help        Show this help.

Without a checkout:
  curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh | bash

Environment:
  CLAUDE_DEVCONTAINER_REPO   Repo to fetch the template from when it is not
                             next to this script. Default:
                             https://github.com/ahoa/claude-devcontainer
  CLAUDE_DEVCONTAINER_REF    Branch, tag or commit to fetch. Default: main
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
PROJECT_NAME=""
NAME_FROM_ARG=0
TMUX_WINDOWS=""
TARGET_DIR=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)      PROJECT_NAME="${2:-}"; NAME_FROM_ARG=1; shift 2 ;;
        --name=*)    PROJECT_NAME="${1#*=}"; NAME_FROM_ARG=1; shift ;;
        --windows)   TMUX_WINDOWS="${2:-}"; shift 2 ;;
        --windows=*) TMUX_WINDOWS="${1#*=}"; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*)          echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)           TARGET_DIR="$1"; shift ;;
    esac
done
TARGET_DIR="${TARGET_DIR:-$PWD}"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: target directory does not exist: $TARGET_DIR" >&2
    exit 1
fi

# ── Template source: local checkout, else download ──────────────────────────
# True only if the directory holds every file we are about to install, so a
# stray template/ in the current directory (likely when piped into bash, where
# SCRIPT_DIR falls back to $PWD) is not mistaken for ours.
template_complete() {
    local dir="$1" f
    [[ -d "$dir" ]] || return 1
    for f in "${TEMPLATE_FILES[@]}"; do
        [[ -f "$dir/$f" ]] || return 1
    done
}

FETCHED_DIR=""
cleanup() { [[ -n "$FETCHED_DIR" ]] && rm -rf "$FETCHED_DIR"; return 0; }

fetch_template() {
    local dep
    for dep in curl tar; do
        command -v "$dep" >/dev/null 2>&1 || {
            echo "ERROR: '$dep' is required to download the template." >&2; exit 1; }
    done

    trap cleanup EXIT
    FETCHED_DIR="$(mktemp -d)"
    echo "Fetching template from $REPO_URL ($REPO_REF)…" >&2
    if ! curl -fsSL "$REPO_URL/archive/$REPO_REF.tar.gz" \
         | tar xz -C "$FETCHED_DIR" --strip-components=1; then
        echo "ERROR: could not download $REPO_URL/archive/$REPO_REF.tar.gz" >&2
        exit 1
    fi

    TEMPLATE_DIR="$FETCHED_DIR/template"
    template_complete "$TEMPLATE_DIR" || {
        echo "ERROR: downloaded archive has no complete template/ directory." >&2; exit 1; }
}

template_complete "$TEMPLATE_DIR" || fetch_template

# ── Helpers ─────────────────────────────────────────────────────────────────
# Prompts on the controlling terminal rather than stdin, which is the script
# itself under `curl … | bash`. Returns non-zero when there is nothing to prompt
# on, leaving the caller to fall back to a default or fail.
prompt_user() {
    local __var="$1" __msg="$2"
    if [[ -t 0 ]]; then
        read -rp "$__msg" "${__var?}"
    elif have_tty; then
        read -rp "$__msg" "${__var?}" </dev/tty
    else
        return 1
    fi
}

# Whether prompting is possible at all — decides re-prompt vs. bail out. /dev/tty
# can exist yet fail to open (no controlling terminal), so probe it for real, in
# a subshell so the failure is ours to report rather than a leaked shell error.
have_tty() {
    if [[ -t 0 ]]; then return 0; fi
    ( : </dev/tty ) 2>/dev/null
}

validate_name() {
    # Docker compose project-name rules: lowercase, starts alnum, then [a-z0-9_-].
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Prints each existing Docker object that would collide with the given name.
# Returns 0 if a collision was found, 1 if clean. Silent (and clean) when the
# Docker daemon is unreachable — name-format validation still applies.
list_conflicts() {
    local n="$1" found=0

    docker_available || return 1

    # An existing compose project of the same name.
    if docker compose ls --all 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$n"; then
        echo "  - docker compose project '$n'"; found=1
    fi
    # The named volume this template would create (<project>_ssh). The Claude
    # login/config volume is NOT checked: it has a fixed name (claude-shared)
    # shared across all projects, so an existing one is expected, not a conflict.
    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "${n}_ssh"; then
        echo "  - docker volume '${n}_ssh'"; found=1
    fi
    # The image compose derives for the devcontainer service (<project>-devcontainer).
    local img
    while IFS= read -r img; do
        [[ -n "$img" ]] && { echo "  - docker image '$img'"; found=1; }
    done < <(docker images --format '{{.Repository}}' 2>/dev/null | grep -E "^${n}[-_]devcontainer$" || true)
    # Leftover containers using the project prefix.
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && { echo "  - docker container '$c'"; found=1; }
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${n}[-_]devcontainer" || true)

    [[ $found -eq 1 ]]
}

# ── Resolve the project name (validate + conflict-check, re-prompt as needed) ─
if ! docker_available; then
    echo "Note: Docker daemon not reachable — skipping conflict checks (name format still validated)." >&2
fi

while :; do
    if [[ -z "$PROJECT_NAME" ]]; then
        if ! prompt_user PROJECT_NAME "Project name (Docker image / compose project / volumes): "; then
            echo "ERROR: no project name given and no terminal to prompt on. Use --name NAME." >&2
            exit 1
        fi
    fi

    if ! validate_name "$PROJECT_NAME"; then
        echo "Invalid name '$PROJECT_NAME'. Use lowercase letters, digits, '-' and '_'; must start with a letter or digit." >&2
        if [[ $NAME_FROM_ARG -eq 1 ]] || ! have_tty; then exit 1; fi
        PROJECT_NAME=""; continue
    fi

    conflicts="$(list_conflicts "$PROJECT_NAME" || true)"
    if [[ -z "$conflicts" ]]; then
        break
    fi

    echo "Name '$PROJECT_NAME' conflicts with existing Docker objects:" >&2
    echo "$conflicts" >&2
    if [[ $FORCE -eq 1 ]]; then
        echo "--force set — continuing anyway (existing volumes/images will be reused)." >&2
        break
    fi
    if [[ $NAME_FROM_ARG -eq 1 ]] || ! have_tty; then
        echo "Pick a different name (re-run with a different --name), or pass --force to reuse them." >&2
        exit 1
    fi
    echo "Choose a different name." >&2
    PROJECT_NAME=""
done

# ── Number of tmux windows ────────────────────────────────────────────────────
if [[ -z "$TMUX_WINDOWS" ]]; then
    prompt_user TMUX_WINDOWS "How many tmux windows (each runs its own Claude)? [1]: " || true
    TMUX_WINDOWS="${TMUX_WINDOWS:-1}"
fi
if [[ ! "$TMUX_WINDOWS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --windows must be a positive integer (got '$TMUX_WINDOWS')." >&2
    exit 1
fi

# ── Install ──────────────────────────────────────────────────────────────────
DEST="$TARGET_DIR/.devcontainer"
if [[ -e "$DEST" && $FORCE -ne 1 ]]; then
    echo "'$DEST' already exists."
    ans=""
    if prompt_user ans "Overwrite the template files in it? [y/N] "; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    else
        echo "ERROR: refusing to overwrite without a terminal. Pass --force." >&2
        exit 1
    fi
fi

mkdir -p "$DEST"
for f in "${TEMPLATE_FILES[@]}"; do
    cp "$TEMPLATE_DIR/$f" "$DEST/$f"
    # Substitute install-time placeholders. -i.bak works on both GNU and BSD sed.
    sed -i.bak \
        -e "s|__PROJECT_NAME__|$PROJECT_NAME|g" \
        -e "s|__TMUX_WINDOWS__|$TMUX_WINDOWS|g" \
        "$DEST/$f"
    rm -f "$DEST/$f.bak"
done

for f in "${EXECUTABLE_FILES[@]}"; do
    chmod +x "$DEST/$f"
done

# Keep the runtime build-hash marker out of git.
if [[ ! -f "$DEST/.gitignore" ]]; then
    printf '.build-hash\n' > "$DEST/.gitignore"
fi

cat <<EOF

✓ Installed Claude devcontainer into $DEST
    project name : $PROJECT_NAME
    tmux windows : $TMUX_WINDOWS

Next:
  1. Add your project's toolchain to $DEST/Dockerfile (Node/JDK/Python/…).
  2. Add any extra outbound hosts to $DEST/allowed-domains.conf,
     and open dev-server ports in $DEST/init-firewall.sh (OPEN_PORTS).
  3. Start it:   (cd "$TARGET_DIR" && ./.devcontainer/start.sh)
     Re-attach:  (cd "$TARGET_DIR" && ./.devcontainer/attach.sh)
EOF
