#!/usr/bin/env bash
#
# install.sh — install a project-agnostic Claude devcontainer setup into a
# target project's .devcontainer/ directory.
#
# Prompts for a project name (used for the Docker image / compose project /
# named volumes) and verifies it does not collide with anything Docker already
# knows about, then asks how many tmux windows (each running its own Claude) the
# session should open and which timezone the container's clock should use.
# Copies the template files, substituting those choices.
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
    tmux.conf
)
# Template-owned but visible, because these three are the commands you run. They
# pass --config to the devcontainer CLI, which is what lets devcontainer.json live
# in .template/ instead of at the path the CLI would discover on its own. Also
# always (re)written.
VISIBLE_TEMPLATE_FILES=(
    start.sh
    attach.sh
    update.sh
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
    ports.conf
    docker-compose.override.yml
)
# All files the template must provide (used to detect a complete template dir).
TEMPLATE_FILES=("${MACHINERY_FILES[@]}" "${USER_FILES[@]}")
# Files that get the executable bit, as installed paths.
EXECUTABLE_FILES=(start.sh attach.sh update.sh .template/init-firewall.sh tools.sh)
# Where the hidden machinery goes, relative to .devcontainer/.
TEMPLATE_SUBDIR=".template"

usage() {
    cat <<'EOF'
Usage: install.sh [options] [target-dir]

Installs the Claude devcontainer template into <target-dir>/.devcontainer/.
target-dir defaults to the current directory.

Options:
  --name NAME       Project name (lowercase [a-z0-9][a-z0-9_-]*). Prompted if omitted.
  --windows N       Number of tmux windows to open (each runs a Claude). Default 1.
  --timezone ZONE   IANA timezone for the container clock. Default Europe/Tallinn.
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

# An IANA zone name: "UTC", "Europe/Tallinn", "America/Argentina/Salta". Checked
# against the host's zoneinfo database when there is one, which catches typos
# early; the container's tzdata is the real authority, so a host without
# zoneinfo (or a zone only the container knows) falls back to a format check.
validate_timezone() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9._+-]+)*$ ]] || return 1
    if [[ -d /usr/share/zoneinfo ]]; then
        [[ -f "/usr/share/zoneinfo/$1" ]] || return 1
    fi
}

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

is_user_file() {
    local f
    for f in "${USER_FILES[@]}"; do
        [[ "$f" == "$1" ]] && return 0
    done
    return 1
}

# Where a template file is installed: machinery is tucked into .template/,
# everything else sits at the top of .devcontainer/ where it can be seen.
dest_path() {
    local f
    for f in "${HIDDEN_FILES[@]}"; do
        [[ "$f" == "$1" ]] && { echo "$DEST/$TEMPLATE_SUBDIR/$1"; return 0; }
    done
    echo "$DEST/$1"
}

# Which template commit this install came from — recorded in .devcontainer/ so
# update.sh knows what to compare against. Prints a short SHA, or nothing when it
# cannot be established.
resolve_template_sha() {
    local sha=""

    # Running from a checkout: that checkout's HEAD is the answer. A dirty tree is
    # marked, since the installed files then match no published commit.
    if [[ -z "$FETCHED_DIR" ]] && sha="$(git -C "$SCRIPT_DIR" rev-parse --short=7 HEAD 2>/dev/null)"; then
        if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]]; then
            sha="$sha-dirty"
        fi
        echo "$sha"
        return 0
    fi

    # Downloaded: a full SHA as the ref is already the answer; otherwise resolve
    # the ref through the API. The `sha` media type returns the bare SHA as plain
    # text, so this needs neither gh nor jq.
    if [[ "$REPO_REF" =~ ^[0-9a-f]{7,40}$ ]]; then
        echo "${REPO_REF:0:7}"
        return 0
    fi
    case "$REPO_URL" in
        https://github.com/*)
            curl -fsSL -m 5 -H 'Accept: application/vnd.github.sha' \
                "https://api.github.com/repos/${REPO_URL#https://github.com/}/commits/$REPO_REF" \
                2>/dev/null | cut -c1-7
            ;;
    esac
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
    # The Claude login/config volume is deliberately NOT checked: it has a fixed
    # name (claude-shared) shared across all projects, so an existing one is
    # expected, not a conflict. The compose file declares no per-project volumes of
    # its own (the Claude devcontainer feature does create one, named after the
    # compose project, but it is disposable and reappears on the next `up`).
    #
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

# Lift a pre-split install's customizations into the user-owned files, before the
# template files that used to hold them are overwritten. Older templates kept the
# project's ports inside init-firewall.sh and its toolchain inside the Dockerfile;
# both are template-owned now, so this is the last moment either can be recovered
# automatically. Recognised by the absence of .template-version, which every
# post-split install writes.
migrate_pre_split_config() {
    [[ -d "$DEST" && ! -f "$DEST/.template-version" ]] || return 0

    # Ports are shell arrays either way, so they can be moved verbatim.
    if [[ ! -f "$DEST/ports.conf" && -f "$DEST/init-firewall.sh" ]] \
       && grep -q '^OPEN_PORTS=(' "$DEST/init-firewall.sh"; then
        {
            echo "# Lifted out of init-firewall.sh by install.sh — ports live here now."
            awk '/^OPEN_PORTS=\(/,/\)/'    "$DEST/init-firewall.sh"
            awk '/^PORT_FORWARDS=\(/,/\)/' "$DEST/init-firewall.sh"
        } > "$DEST/ports.conf"
        echo "→ Lifted OPEN_PORTS / PORT_FORWARDS out of init-firewall.sh into ports.conf"
    fi

    # The host list keeps its format and only changes name.
    if [[ ! -f "$DEST/domains.conf" && -f "$DEST/allowed-domains.conf" ]]; then
        mv "$DEST/allowed-domains.conf" "$DEST/domains.conf"
        echo "→ Renamed allowed-domains.conf to domains.conf (your entries are untouched)"
    fi

    # Extra services used to be added straight into docker-compose.yml, which the
    # template owns and is about to replace. Losing them silently is worse than it
    # sounds: a PORT_FORWARDS entry pointing at a service that no longer exists
    # makes init-firewall.sh exit 1, and the container then fails to start at all.
    if [[ -f "$DEST/docker-compose.yml" ]] && awk '
        /^services:/ { s=1; next }
        /^[^ #]/     { s=0 }
        s && /^  [A-Za-z0-9_.-]+:/ {
            name=$1; sub(/:$/, "", name)
            if (name != "devcontainer") found=1
        }
        END { exit !found }' "$DEST/docker-compose.yml"; then
        cp "$DEST/docker-compose.yml" "$DEST/docker-compose.from-old.yml"
        MIGRATED_COMPOSE=1
        echo "→ Saved your old docker-compose.yml to docker-compose.from-old.yml (it defines extra services)"
    fi

    # The toolchain is Dockerfile syntax, not shell, so it cannot be converted
    # mechanically — keep it verbatim beside the new script for the user to move.
    local toolchain
    toolchain="$(awk '/Add your project.s toolchain below/{f=1; next} f' "$DEST/Dockerfile" 2>/dev/null \
                 | grep -vE '^[[:space:]]*#|^[[:space:]]*$|^WORKDIR ' || true)"
    if [[ -n "$toolchain" ]]; then
        printf '%s\n' "$toolchain" > "$DEST/tools.from-dockerfile"
        MIGRATED_TOOLCHAIN=1
        echo "→ Saved your Dockerfile toolchain lines to tools.from-dockerfile"
    fi
}

# Remove machinery left at the top of .devcontainer/ by an install that predates
# the move into .template/. Without this the old copies sit beside the new hidden
# ones — same names, stale contents, no indication which is live.
clean_stale_machinery() {
    local f stale=()
    for f in "${HIDDEN_FILES[@]}"; do
        [[ -f "$DEST/$f" ]] && stale+=("$f")
    done
    [[ ${#stale[@]} -gt 0 ]] || return 0
    rm -f "${stale[@]/#/$DEST/}"
    echo "→ Moved ${stale[*]} into $TEMPLATE_SUBDIR/ (they are template-owned)"
}

# Migrate a pre-shared-login install: older versions of this template gave
# every project its own <project>_claude volume (and thus its own /login).
# When such a volume exists, seed the shared claude-shared volume from it so
# the login carries over — unless claude-shared already holds a login (another
# project migrated first; one login already covers every project). The old
# volume is left in place for the user to remove once the new setup works.
migrate_claude_volume() {
    local old="${PROJECT_NAME}_claude"
    docker_available || return 0
    docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$old" || return 0

    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "claude-shared" \
       && docker run --rm -v claude-shared:/v alpine test -f /v/.credentials.json 2>/dev/null; then
        echo "Note: 'claude-shared' already holds a Claude login — leaving old volume '$old' untouched."
        return 0
    fi

    echo "Migrating Claude login/config from '$old' into shared volume 'claude-shared'…"
    docker volume create claude-shared >/dev/null
    if docker run --rm -v "$old":/from -v claude-shared:/to alpine cp -a /from/. /to; then
        echo "Migrated. Once the new setup works, remove the old volume with: docker volume rm $old"
    else
        echo "WARNING: copy failed — 'claude-shared' may be incomplete. Re-run the installer to retry, or copy manually:" >&2
        echo "  docker run --rm -v $old:/from -v claude-shared:/to alpine cp -a /from/. /to" >&2
    fi
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

# ── Container timezone ────────────────────────────────────────────────────────
# Without this the container runs UTC. Re-prompts on a bad zone when there is a
# terminal; a bad --timezone is fatal.
while :; do
    if [[ -z "$TIMEZONE" ]]; then
        prompt_user TIMEZONE "Container timezone (IANA name) [$DEFAULT_TIMEZONE]: " || true
        TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"
    fi

    if validate_timezone "$TIMEZONE"; then break; fi

    echo "Unknown or malformed timezone '$TIMEZONE'. Use an IANA name, e.g. Europe/Tallinn or UTC." >&2
    if [[ $TZ_FROM_ARG -eq 1 ]] || ! have_tty; then exit 1; fi
    TIMEZONE=""
done

# ── Install ──────────────────────────────────────────────────────────────────
DEST="$TARGET_DIR/.devcontainer"
if [[ -e "$DEST" && $FORCE -ne 1 ]]; then
    echo "'$DEST' already exists."
    echo "Template files will be replaced; your ${#USER_FILES[@]} config files (${USER_FILES[*]}) are kept as they are."
    ans=""
    if prompt_user ans "Continue? [y/N] "; then
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    else
        echo "ERROR: refusing to overwrite without a terminal. Pass --force." >&2
        exit 1
    fi
fi

# Recover a pre-split install's toolchain/ports before overwriting the files that
# held them. No-op on fresh installs and on anything already carrying a stamp.
MIGRATED_TOOLCHAIN=0
MIGRATED_COMPOSE=0
migrate_pre_split_config

mkdir -p "$DEST/$TEMPLATE_SUBDIR"
KEPT_FILES=()
for f in "${TEMPLATE_FILES[@]}"; do
    dest="$(dest_path "$f")"
    # A user-owned file that already exists is left untouched — this is what makes
    # a re-run an update rather than a clobber.
    if is_user_file "$f" && [[ -e "$dest" ]]; then
        KEPT_FILES+=("$f")
        continue
    fi
    cp "$TEMPLATE_DIR/$f" "$dest"
    # Substitute install-time placeholders. -i.bak works on both GNU and BSD sed.
    sed -i.bak \
        -e "s|__PROJECT_NAME__|$PROJECT_NAME|g" \
        -e "s|__TMUX_WINDOWS__|$TMUX_WINDOWS|g" \
        -e "s|__TIMEZONE__|$TIMEZONE|g" \
        "$dest"
    rm -f "$dest.bak"
done

# Only once the hidden copies are in place, so a failure above leaves the old
# layout intact rather than a half-installed one.
clean_stale_machinery

for f in "${EXECUTABLE_FILES[@]}"; do
    chmod +x "$DEST/$f"
done

# Keep runtime markers out of git: the build-input hash and the update-check cache.
if [[ ! -f "$DEST/.gitignore" ]]; then
    printf '.build-hash\n.update-check\n' > "$DEST/.gitignore"
fi

# Record which template version this install came from, plus the answers needed to
# re-render it. update.sh reads this to know what to compare against and how to
# re-run the installer without asking again. Meant to be committed — it travels
# with the project, unlike the two runtime markers above.
TEMPLATE_SHA="$(resolve_template_sha || true)"
cat > "$DEST/.template-version" <<EOF
# Written by install.sh — do not edit by hand. Commit this file.
TEMPLATE_SHA=${TEMPLATE_SHA:-unknown}
TEMPLATE_REPO=$REPO_URL
TEMPLATE_REF=$TRACK_REF
PROJECT_NAME=$PROJECT_NAME
TMUX_WINDOWS=$TMUX_WINDOWS
TIMEZONE=$TIMEZONE
EOF

# Carry an old per-project Claude login over to the shared volume (no-op on
# fresh installs and when the shared volume is already logged in).
migrate_claude_volume

cat <<EOF

✓ Installed Claude devcontainer into $DEST
    project name : $PROJECT_NAME
    tmux windows : $TMUX_WINDOWS
    timezone     : $TIMEZONE
EOF

if [[ ${#KEPT_FILES[@]} -gt 0 ]]; then
    printf '    kept as-is   : %s\n' "${KEPT_FILES[*]}"
fi

if [[ $MIGRATED_TOOLCHAIN -eq 1 ]]; then
    cat <<EOF

⚠  Your toolchain used to live in the Dockerfile, which this install replaced.
   The old lines are in $DEST/tools.from-dockerfile.
   Move them into $DEST/tools.sh as plain shell
   (drop the leading 'RUN '), then delete the .from-dockerfile file.
   Until you do, the image builds without your toolchain.
EOF
fi

if [[ $MIGRATED_COMPOSE -eq 1 ]]; then
    cat <<EOF

⚠  Your old docker-compose.yml defined services beyond the devcontainer, and this
   install replaced that file. A copy is in $DEST/docker-compose.from-old.yml.
   Move those service definitions into $DEST/docker-compose.override.yml,
   then delete the .from-old.yml file.
   Do this before starting: if ports.conf forwards a port to a service that no
   longer exists, the firewall aborts and the container will not start.
EOF
fi

cat <<EOF

The four files at the top of $DEST are yours to edit;
everything else there, including $TEMPLATE_SUBDIR/, is the template's and is
replaced on update.

Next:
  1. Add your project's toolchain to $DEST/tools.sh (Node/JDK/Python/…).
  2. Add any extra outbound hosts to $DEST/domains.conf, and
     dev-server / forwarded ports to $DEST/ports.conf.
  3. Extra compose services go in $DEST/docker-compose.override.yml.
  4. Start it:   (cd "$TARGET_DIR" && ./.devcontainer/start.sh)
     Re-attach:  (cd "$TARGET_DIR" && ./.devcontainer/attach.sh)
EOF
