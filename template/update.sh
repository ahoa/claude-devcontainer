#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated (by itself, among other things).
#
# update.sh — pull a newer version of the devcontainer template into this project.
#
# Updating is just a re-run of the installer at a newer commit: it rewrites
# .template/ and the scripts beside it, and leaves the three visible user-owned
# files (tools.sh, domains.conf, firewall.sh, docker-compose.override.yml)
# exactly as they are.
# That split is what makes an update safe, so there is nothing to merge here.
#
#   ./update.sh            update to the latest commit on the recorded ref
#   ./update.sh --check    report whether an update exists (used by start.sh)
#   ./update.sh --ref REF  update to a specific branch, tag or commit
#   ./update.sh --force    update even on a dirty tree / when already current
#
# Requires a clean git tree under .devcontainer/, so `git diff` shows exactly what
# the update changed and `git checkout` undoes it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$SCRIPT_DIR/.template-version"
# Remote SHA cache, refreshed at most once a day — a --check on every start.sh
# must not cost a network round-trip.
CACHE="$SCRIPT_DIR/.update-check"
CACHE_MAX_AGE_MIN=1440

CHECK_ONLY=0
FORCE=0
REF_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK_ONLY=1; shift ;;
        --force)   FORCE=1; shift ;;
        --ref)     REF_OVERRIDE="${2:-}"; shift 2 ;;
        --ref=*)   REF_OVERRIDE="${1#*=}"; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Recorded install ─────────────────────────────────────────────────────────
# Defaults cover a .devcontainer/ installed before stamping existed; the values
# are re-derived from the installed files below.
TEMPLATE_SHA=""
TEMPLATE_REPO="https://github.com/ahoa/claude-devcontainer"
TEMPLATE_REF="main"
PROJECT_NAME=""
TMUX_WINDOWS=""
TIMEZONE=""
CLAUDE_LOGIN=""
DOCKER_SOCKET=""

# The stamp is read one key at a time and is never sourced.
#
# It lives in the project tree, which is bind-mounted into the container, so
# anything that runs in there can write it. `source` ran the contents of that file
# as shell — here, on the host, outside the container this template exists to
# sandbox. start.sh reaches this code on every single run through --check, so one
# line appended to .template-version was host code execution at the next start.
# Every value is validated below, before it is used.
stamp_value() {
    [[ -f "$STAMP" ]] || return 0
    # tail -1: the last assignment wins, which is what `source` did.
    sed -n "s/^$1=//p" "$STAMP" | tail -1
}
if [[ -f "$STAMP" ]]; then
    TEMPLATE_SHA="$(stamp_value TEMPLATE_SHA)"
    PROJECT_NAME="$(stamp_value PROJECT_NAME)"
    TMUX_WINDOWS="$(stamp_value TMUX_WINDOWS)"
    TIMEZONE="$(stamp_value TIMEZONE)"
    CLAUDE_LOGIN="$(stamp_value CLAUDE_LOGIN)"
    DOCKER_SOCKET="$(stamp_value DOCKER_SOCKET)"
    # These two have a default worth keeping when the key is absent.
    v="$(stamp_value TEMPLATE_REPO)"; [[ -n "$v" ]] && TEMPLATE_REPO="$v"
    v="$(stamp_value TEMPLATE_REF)";  [[ -n "$v" ]] && TEMPLATE_REF="$v"
fi
[[ -n "$REF_OVERRIDE" ]] && TEMPLATE_REF="$REF_OVERRIDE"

# A pre-stamp install still knows its answers — they are substituted into the
# installed files, so read them back rather than asking again.
#
# The machinery moved into .template/ at some point; a project that has not
# updated since still has it flat in .devcontainer/, so look in both places.
find_machinery() {
    local f
    for f in "$SCRIPT_DIR/.template/$1" "$SCRIPT_DIR/$1"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$(find_machinery docker-compose.yml)" 2>/dev/null || true)"
fi
if [[ -z "$TMUX_WINDOWS" ]]; then
    TMUX_WINDOWS="$(sed -n 's/^WINDOWS="\${TMUX_WINDOWS:-\([0-9]*\)}".*/\1/p' "$SCRIPT_DIR/start.sh" 2>/dev/null | head -1)"
fi
if [[ -z "$TIMEZONE" ]]; then
    TIMEZONE="$(sed -n 's/^ENV TZ=\(.*\)/\1/p' "$(find_machinery Dockerfile)" 2>/dev/null | head -1)"
fi
[[ -z "$PROJECT_NAME" ]] && { echo "ERROR: cannot determine the project name — is $SCRIPT_DIR a devcontainer install?" >&2; exit 1; }
TMUX_WINDOWS="${TMUX_WINDOWS:-1}"
TIMEZONE="${TIMEZONE:-Europe/Tallinn}"
# Installs from before these two questions existed all share one login volume,
# and all mount the host Docker socket.
CLAUDE_LOGIN="${CLAUDE_LOGIN:-shared}"
DOCKER_SOCKET="${DOCKER_SOCKET:-on}"

# ── Validate the recorded values ─────────────────────────────────────────────
# All of them come out of files inside the project, and the container can write
# those files. Two decide where code comes from: TEMPLATE_REPO and the SHA name
# the install.sh that this script downloads and runs with bash. The rest become
# its arguments. So each value must look like what it is, and anything else stops
# the update rather than reaching a command line.
bad_value() {
    echo "ERROR: $STAMP holds an invalid $1: '$2'" >&2
    echo "       Correct that file by hand, or re-install the template." >&2
    exit 1
}
[[ -z "$TEMPLATE_SHA" || "$TEMPLATE_SHA" == "unknown" || "$TEMPLATE_SHA" =~ ^[0-9a-f]{7,40}$ ]] \
    || bad_value TEMPLATE_SHA "$TEMPLATE_SHA"
[[ "$TEMPLATE_REPO" =~ ^https://github\.com/[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,64}$ ]] \
    || bad_value TEMPLATE_REPO "$TEMPLATE_REPO"
[[ "$TEMPLATE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ && "$TEMPLATE_REF" != *..* ]] \
    || bad_value TEMPLATE_REF "$TEMPLATE_REF"
[[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || bad_value PROJECT_NAME "$PROJECT_NAME"
[[ "$TMUX_WINDOWS" =~ ^[1-9][0-9]*$ ]]         || bad_value TMUX_WINDOWS "$TMUX_WINDOWS"
[[ "$TIMEZONE" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9._+-]+)*$ && "$TIMEZONE" != *..* ]] \
    || bad_value TIMEZONE "$TIMEZONE"
[[ "$CLAUDE_LOGIN" == "shared" || "$CLAUDE_LOGIN" == "project" ]] \
    || bad_value CLAUDE_LOGIN "$CLAUDE_LOGIN"
[[ "$DOCKER_SOCKET" == "on" || "$DOCKER_SOCKET" == "off" ]] \
    || bad_value DOCKER_SOCKET "$DOCKER_SOCKET"

# ── Latest remote SHA ────────────────────────────────────────────────────────
# The `sha` media type returns the bare commit SHA as plain text, so resolving a
# ref needs neither `gh` nor `jq` — just curl. Public repo, so no auth either.
api_url() {
    case "$TEMPLATE_REPO" in
        https://github.com/*) echo "https://api.github.com/repos/${TEMPLATE_REPO#https://github.com/}" ;;
        *)                    return 1 ;;
    esac
}

fetch_remote_sha() {
    local api
    api="$(api_url)" || return 1
    curl -fsSL -m 5 -H 'Accept: application/vnd.github.sha' \
        "$api/commits/$TEMPLATE_REF" 2>/dev/null | cut -c1-7
}

# The cache exists so that --check on every start.sh is free. Only --check may read
# it — including as the fallback when the refresh fails, where a cached SHA still
# reports a known-pending update instead of erroring out inside start.sh.
# An explicit ./update.sh never reads it: deciding "already up to date" from a SHA
# that is up to a day old is how a freshly pushed template silently fails to
# arrive. Offline, it errors out below rather than claiming to be current.
REMOTE_SHA=""
if [[ $CHECK_ONLY -eq 1 && -z "$REF_OVERRIDE" && -n "$(find "$CACHE" -mmin "-$CACHE_MAX_AGE_MIN" 2>/dev/null)" ]]; then
    REMOTE_SHA="$(cat "$CACHE" 2>/dev/null || true)"
else
    REMOTE_SHA="$(fetch_remote_sha || true)"
    # An explicit ref is not what the cache tracks, so it neither fills nor reads it.
    if [[ -z "$REF_OVERRIDE" ]]; then
        if [[ -n "$REMOTE_SHA" ]]; then
            echo "$REMOTE_SHA" > "$CACHE"
        elif [[ $CHECK_ONLY -eq 1 ]]; then
            REMOTE_SHA="$(cat "$CACHE" 2>/dev/null || true)"
        fi
    fi
fi

if [[ -z "$REMOTE_SHA" ]]; then
    [[ $CHECK_ONLY -eq 1 ]] && exit 0   # stay silent inside start.sh
    echo "ERROR: could not resolve $TEMPLATE_REPO ref '$TEMPLATE_REF'. Check your network." >&2
    exit 1
fi

CURRENT="${TEMPLATE_SHA:-unknown}"

# ── --check: report and exit ─────────────────────────────────────────────────
if [[ $CHECK_ONLY -eq 1 ]]; then
    if [[ "$CURRENT" == "$REMOTE_SHA" ]]; then
        exit 0
    fi
    # 33 = yellow. Exit 1 marks "update available" for scripted callers.
    printf '\033[33m⚡ devcontainer template update: %s → %s — run ./.devcontainer/update.sh\033[0m\n' \
        "$CURRENT" "$REMOTE_SHA"
    exit 1
fi

if [[ "$CURRENT" == "$REMOTE_SHA" && $FORCE -ne 1 ]]; then
    echo "✓ devcontainer template already up to date ($CURRENT)"
    exit 0
fi

echo "Updating devcontainer template: $CURRENT → $REMOTE_SHA"
# Printed because the next step runs install.sh from this repo. The repo is
# recorded in the project, so a reader can see when it is not the expected one.
echo "  source: $TEMPLATE_REPO ($TEMPLATE_REF)"

# ── Refuse to work on a dirty tree ───────────────────────────────────────────
# git is the only undo for this operation, so it has to be usable.
if [[ $FORCE -ne 1 ]]; then
    if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "ERROR: $PROJECT_DIR is not a git repository — nothing to undo an update with." >&2
        echo "       Commit the project to git first, or re-run with --force." >&2
        exit 1
    fi
    if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain -- "$SCRIPT_DIR" 2>/dev/null)" ]]; then
        echo "ERROR: .devcontainer/ has uncommitted changes." >&2
        echo "       Commit or stash them first, so 'git diff' after the update shows only the update." >&2
        echo "       Or re-run with --force to update anyway." >&2
        exit 1
    fi
fi

# ── Re-run the installer at the target commit ───────────────────────────────
# A pre-split install's toolchain is lifted into the user-owned files by the
# installer itself (it recognises the old layout by the missing stamp), so there is
# nothing to do for that here.
# Pinned to the resolved SHA rather than the ref, so what gets installed is
# exactly what was compared against — and is what the new stamp will record.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! curl -fsSL "$TEMPLATE_REPO/raw/$REMOTE_SHA/install.sh" -o "$TMP/install.sh"; then
    echo "ERROR: could not download install.sh at $REMOTE_SHA" >&2
    exit 1
fi

# Only pass flags the target installer actually knows: --ref can point at a commit
# older than a flag, and an unknown option there is fatal. The installer's own
# default then applies, which is the right fallback.
INSTALL_ARGS=(--name "$PROJECT_NAME" --windows "$TMUX_WINDOWS" --force)
grep -q -- '--timezone' "$TMP/install.sh" && INSTALL_ARGS+=(--timezone "$TIMEZONE")
grep -q -- '--login' "$TMP/install.sh" && INSTALL_ARGS+=(--login "$CLAUDE_LOGIN")
grep -q -- '--docker' "$TMP/install.sh" && INSTALL_ARGS+=(--docker "$DOCKER_SOCKET")

# ── Run the installer, then stop reading this file ───────────────────────────
# The installer overwrites this file.
# bash reads a script one command at a time, and seeks back to the byte offset
# after each command. Once the file changes, bash reads the new file from the
# old offset. That offset lands mid-line, and bash stops with a syntax error
# that names a line this version never had.
# The brace group below is one command, so bash parses all of it before the
# installer runs. The exit at the end keeps bash from reading the file again.
{
  CLAUDE_DEVCONTAINER_REPO="$TEMPLATE_REPO" \
  CLAUDE_DEVCONTAINER_REF="$REMOTE_SHA" \
  CLAUDE_DEVCONTAINER_TRACK_REF="$TEMPLATE_REF" \
      bash "$TMP/install.sh" "${INSTALL_ARGS[@]}" "$PROJECT_DIR"

  # Installers older than the stamp itself write no .template-version, which would
  # leave --check offering the same update forever. Record it here when the
  # installer did not — a no-op whenever it did.
  if ! grep -qx "TEMPLATE_SHA=$REMOTE_SHA" "$STAMP" 2>/dev/null; then
    cat > "$STAMP" <<EOF
# Written by update.sh — do not edit by hand. Commit this file.
TEMPLATE_SHA=$REMOTE_SHA
TEMPLATE_REPO=$TEMPLATE_REPO
TEMPLATE_REF=$TEMPLATE_REF
PROJECT_NAME=$PROJECT_NAME
TMUX_WINDOWS=$TMUX_WINDOWS
TIMEZONE=$TIMEZONE
CLAUDE_LOGIN=$CLAUDE_LOGIN
DOCKER_SOCKET=$DOCKER_SOCKET
EOF
  fi

  cat <<EOF

Next:
  1. Review what changed:  git -C "$PROJECT_DIR" diff -- .devcontainer
  2. Start it:             ./.devcontainer/start.sh
     start.sh sees the changed build inputs and does a clean rebuild.
EOF

  exit 0
}
