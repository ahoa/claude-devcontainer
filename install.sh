#!/usr/bin/env bash
#
# install.sh — install a project-agnostic Claude devcontainer setup into a
# target project's .devcontainer/ directory.
#
# Prompts for a project name (used for the Docker image / compose project /
# named volumes) and verifies it does not collide with anything Docker already
# knows about, then asks how many tmux windows (each running its own Claude) the
# session should open, which timezone the container's clock should use, whether
# Claude's login is shared with the other projects or belongs to this one, and
# whether the container gets the host Docker socket.
# Copies the template files, substituting those choices.
#
# Works both from a checkout and standalone (curl … | bash): when there is no
# template/ next to the script, the template is downloaded from GitHub into a
# temp dir. Prompts are read from /dev/tty, so piping the script into bash still
# lets you answer them.
#
# The parts of the installer are in installer/, by facet: the questions, what
# an existing install answered, the migrations from earlier layouts, and the
# file writer. This script sources them once it knows where the template is.
#
set -euo pipefail

# Falls back to $PWD when there is no script file to locate (curl … | bash).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$PWD}")" 2>/dev/null && pwd || echo "$PWD")"
TEMPLATE_DIR="$SCRIPT_DIR/template"

# Where to fetch the template from when it is not available locally.
REPO_URL="${CLAUDE_DEVCONTAINER_REPO:-https://github.com/ahoa/claude-devcontainer}"
REPO_REF="${CLAUDE_DEVCONTAINER_REF:-main}"
# The ref recorded in .devcontainer/.template-version for update.sh to keep
# tracking. Defaults to the ref installed from; update.sh sets it explicitly
# because it pins REPO_REF to an exact SHA (so the update installs precisely what
# it compared against) while the project should go on tracking the branch.
TRACK_REF="${CLAUDE_DEVCONTAINER_TRACK_REF:-$REPO_REF}"

# Template-owned machinery, installed into .devcontainer/.template/ — out of sight
# because nothing in it is meant to be edited by hand. Always (re)written, so a
# re-run picks up template changes.
HIDDEN_FILES=(
    devcontainer.json
    devcontainer-lock.json
    Dockerfile
    docker-compose.yml
    init-firewall.sh
    domains-base.conf
    fw-watch.sh
    docker-check.sh
    tmux.conf
    ca-plugin-flag.sh
    ca-claude.zsh
    build-hash.sh
    # The shared base image, which every project from one template version
    # builds identically (start.sh).
    base/Dockerfile
    base/devcontainer.json
    base/devcontainer-lock.json
)
# Template-owned but visible, because these are the commands you run. They pass
# --config to the devcontainer CLI, which is what lets devcontainer.json live in
# .template/ instead of at the path the CLI would discover on its own. Also always
# (re)written.
VISIBLE_TEMPLATE_FILES=(
    start.sh
    attach.sh
    loop.sh
    update.sh
    update-fw.sh
)
MACHINERY_FILES=("${HIDDEN_FILES[@]}" "${VISIBLE_TEMPLATE_FILES[@]}")
# User-owned files: seeded once and never overwritten, so a re-run cannot clobber
# a project's toolchain, ports, outbound hosts or compose additions. Everything a
# project needs to customise must live in one of these — that is what makes
# re-running the installer a safe update.
# They stay at the top of .devcontainer/, so what is visible there is what you are
# meant to touch.
USER_FILES=(
    tools.sh
    domains.conf
    firewall.sh
    docker-compose.override.yml
)
# All files the template must provide (used to detect a complete template dir).
TEMPLATE_FILES=("${MACHINERY_FILES[@]}" "${USER_FILES[@]}")
# Files that get the executable bit, as installed paths.
EXECUTABLE_FILES=(start.sh attach.sh loop.sh update.sh update-fw.sh .template/init-firewall.sh .template/fw-watch.sh .template/docker-check.sh .template/build-hash.sh tools.sh)
# Where the hidden machinery goes, relative to .devcontainer/.
TEMPLATE_SUBDIR=".template"
# What the devcontainer's compose project name adds to the project name. The
# container mounts the repo at /workspace/<project name>, so a bare
# `docker compose` in the repo takes <project name> as its own project name.
# Without this suffix that is the devcontainer's project, and `docker compose
# down` in the repo stops the container that runs the session. start.sh knows the
# same suffix, to remove the container of an install from before it.
DC_SUFFIX="-dc"

usage() {
    cat <<'EOF'
Usage: install.sh [options] [target-dir]

Installs the Claude devcontainer template into <target-dir>/.devcontainer/.
target-dir defaults to the current directory.

Options:
  --name NAME       Project name (lowercase [a-z0-9][a-z0-9_-]*). Prompted if omitted.
  --windows N       Number of tmux windows to open (each runs a Claude). Default 1.
  --timezone ZONE   IANA timezone for the container clock. Default Europe/Tallinn.
  --login MODE      Where Claude's login lives: 'shared' (one login for every
                    project from this template) or 'project' (a login of this
                    project's own). Default shared. Prompted if omitted.
  --docker MODE     'on' gives the container the host Docker socket, through the
                    docker-outside-of-docker feature, which also gives it control
                    of the host. 'off' leaves the feature out. Default on.
                    Prompted if omitted.
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
TIMEZONE=""
TZ_FROM_ARG=0
CLAUDE_LOGIN=""
LOGIN_FROM_ARG=0
DOCKER_SOCKET=""
DOCKER_FROM_ARG=0
TARGET_DIR=""
FORCE=0
# Timezone offered when the prompt is accepted with Enter, and used verbatim in a
# non-interactive install that passes no --timezone.
DEFAULT_TIMEZONE="Europe/Tallinn"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)      PROJECT_NAME="${2:-}"; NAME_FROM_ARG=1; shift 2 ;;
        --name=*)    PROJECT_NAME="${1#*=}"; NAME_FROM_ARG=1; shift ;;
        --windows)   TMUX_WINDOWS="${2:-}"; shift 2 ;;
        --windows=*) TMUX_WINDOWS="${1#*=}"; shift ;;
        --timezone)  TIMEZONE="${2:-}"; TZ_FROM_ARG=1; shift 2 ;;
        --timezone=*) TIMEZONE="${1#*=}"; TZ_FROM_ARG=1; shift ;;
        --login)     CLAUDE_LOGIN="${2:-}"; LOGIN_FROM_ARG=1; shift 2 ;;
        --login=*)   CLAUDE_LOGIN="${1#*=}"; LOGIN_FROM_ARG=1; shift ;;
        --docker)    DOCKER_SOCKET="${2:-}"; DOCKER_FROM_ARG=1; shift 2 ;;
        --docker=*)  DOCKER_SOCKET="${1#*=}"; DOCKER_FROM_ARG=1; shift ;;
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
# The half-written file of the install loop below. Named here so that an aborted
# run leaves no .new file behind in the project.
PENDING_WRITE=""
cleanup() {
    [[ -n "$FETCHED_DIR" ]] && rm -rf "$FETCHED_DIR"
    [[ -n "$PENDING_WRITE" ]] && rm -f "$PENDING_WRITE" "$PENDING_WRITE.bak"
    return 0
}
trap cleanup EXIT

fetch_template() {
    local dep
    for dep in curl tar; do
        command -v "$dep" >/dev/null 2>&1 || {
            echo "ERROR: '$dep' is required to download the template." >&2; exit 1; }
    done

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

# ── The parts of the installer ──────────────────────────────────────────────
# Sourced, not run: they share the globals of this script, and the order below
# is the order of an install. The archive a pipe install downloads holds them
# too. installer/README.md is the map.
INSTALLER_DIR="$(dirname "$TEMPLATE_DIR")/installer"
for part in prompt detect migrate write; do
    [[ -f "$INSTALLER_DIR/$part.sh" ]] || {
        echo "ERROR: $INSTALLER_DIR/$part.sh is missing — not a complete template checkout." >&2; exit 1; }
done
# shellcheck source=installer/prompt.sh
source "$INSTALLER_DIR/prompt.sh"
# shellcheck source=installer/detect.sh
source "$INSTALLER_DIR/detect.sh"
# shellcheck source=installer/migrate.sh
source "$INSTALLER_DIR/migrate.sh"
# shellcheck source=installer/write.sh
source "$INSTALLER_DIR/write.sh"

# ── The five questions ──────────────────────────────────────────────────────
EXISTING_NAME=""
EXISTING_WINDOWS=""
EXISTING_TIMEZONE=""
EXISTING_LOGIN=""
EXISTING_DOCKER=""
detect_existing_answers
if [[ -n "$EXISTING_NAME" ]]; then
    echo "Found an existing install in $TARGET_DIR/.devcontainer — its answers are the defaults below."
fi

if ! docker_available; then
    echo "Note: Docker daemon not reachable — skipping conflict checks (name format still validated)." >&2
fi

ask_project_name
ask_windows
ask_timezone
ask_login
ask_docker

# ── Install ──────────────────────────────────────────────────────────────────
DEST="$TARGET_DIR/.devcontainer"
confirm_overwrite

# Recover a pre-split install's toolchain/ports before overwriting the files that
# held them. No-op on fresh installs and on anything already carrying a stamp.
BACKED_UP=()
MIGRATED_OPEN_PORTS=""
MIGRATED_FORWARDS=0
migrate_pre_split_config

write_template_files

# Only once the hidden copies are in place, so a failure above leaves the old
# layout intact rather than a half-installed one.
clean_stale_machinery

finish_template_files
write_stamp

# Carry an old per-project Claude login over to the shared volume (no-op on fresh
# installs and when the shared volume is already logged in). Only for the shared
# choice — a project-scoped login goes on using that same <project>_claude volume,
# so there is nothing to move.
if [[ "$CLAUDE_LOGIN" == "shared" ]]; then
    migrate_claude_volume
fi

# Reach the sessions that a pre-per-project install left behind. Runs after the
# login migration above, so it sees whatever that one moved in.
migrate_claude_sessions

print_summary
