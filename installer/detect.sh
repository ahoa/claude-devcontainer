# shellcheck shell=bash
#
# What is already there, for install.sh: the answers an earlier install gave,
# the Docker objects a project name would collide with, and the commit the
# template came from. Sourced by install.sh, shares its globals.

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# What an existing install in the target directory already answered, so a re-run can
# offer those as defaults instead of asking blind. A wrong project name here is not
# a typo but a second set of Docker objects, so it matters more than the others.
#
# Prefers the stamp; without one (an install predating it) the values are read back
# out of the installed files, which is where they were substituted. Machinery may be
# in .template/ or, before that move, flat in .devcontainer/.
detect_existing_answers() {
    # Separate statements: under `set -u`, a name declared in the same `local` is not
    # yet visible to a later assignment in that statement.
    local dest="$TARGET_DIR/.devcontainer"
    local stamp="$dest/.template-version"
    local f
    local vol
    [[ -d "$dest" ]] || return 0

    if [[ -f "$stamp" ]]; then
        EXISTING_NAME="$(sed -n 's/^PROJECT_NAME=//p'  "$stamp" | head -1)"
        EXISTING_WINDOWS="$(sed -n 's/^TMUX_WINDOWS=//p' "$stamp" | head -1)"
        EXISTING_TIMEZONE="$(sed -n 's/^TIMEZONE=//p'    "$stamp" | head -1)"
        EXISTING_LOGIN="$(sed -n 's/^CLAUDE_LOGIN=//p'   "$stamp" | head -1)"
        EXISTING_DOCKER="$(sed -n 's/^DOCKER_SOCKET=//p'  "$stamp" | head -1)"
    fi

    for f in "$dest/.template/docker-compose.yml" "$dest/docker-compose.yml"; do
        [[ -z "$EXISTING_NAME" && -f "$f" ]] || continue
        EXISTING_NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$f")"
    done
    if [[ -z "$EXISTING_WINDOWS" && -f "$dest/start.sh" ]]; then
        EXISTING_WINDOWS="$(sed -n 's/^WINDOWS="\${TMUX_WINDOWS:-\([0-9]*\)}".*/\1/p' "$dest/start.sh" | head -1)"
    fi
    for f in "$dest/.template/Dockerfile" "$dest/Dockerfile"; do
        [[ -z "$EXISTING_TIMEZONE" && -f "$f" ]] || continue
        EXISTING_TIMEZONE="$(sed -n 's/^ENV TZ=//p' "$f" | head -1)"
    done
    # An install from before this question existed shares one login volume, and
    # its start.sh holds no CLAUDE_VOLUME line at all.
    if [[ -z "$EXISTING_LOGIN" && -f "$dest/start.sh" ]]; then
        vol="$(sed -n 's/^CLAUDE_VOLUME="\(.*\)"$/\1/p' "$dest/start.sh" | head -1)"
        if [[ -z "$vol" || "$vol" == "claude-shared" ]]; then
            EXISTING_LOGIN="shared"
        else
            EXISTING_LOGIN="project"
        fi
    fi
    # Without a stamp, the feature line in devcontainer.json tells: an "off"
    # install has it commented out. Every install from before this question
    # existed had the feature, and mounted the socket in its compose file too,
    # so the compose file is the second witness.
    if [[ -z "$EXISTING_DOCKER" ]]; then
        for f in "$dest/.template/devcontainer.json" "$dest/devcontainer.json"; do
            [[ -f "$f" ]] || continue
            grep -q '^ *"ghcr.io/devcontainers/features/docker-outside-of-docker' "$f" && EXISTING_DOCKER="on"
            break
        done
    fi
    if [[ -z "$EXISTING_DOCKER" ]]; then
        for f in "$dest/.template/docker-compose.yml" "$dest/docker-compose.yml"; do
            [[ -f "$f" ]] || continue
            if grep -q '^ *- */var/run/docker\.sock:' "$f"; then
                EXISTING_DOCKER="on"
            else
                EXISTING_DOCKER="off"
            fi
            break
        done
    fi
}

# git@github.com:owner/repo.git and https://github.com/owner/repo name the same
# repo. Reduce either form to "github.com/owner/repo", so the two compare equal.
normalize_repo_url() {
    local u="${1%.git}"
    u="${u#ssh://}"; u="${u#https://}"; u="${u#http://}"; u="${u#git@}"
    echo "${u/://}"
}

# Which commit of $REPO_URL this install came from — recorded in .devcontainer/ so
# update.sh knows what to compare against. Prints a short SHA, or nothing when it
# cannot be established.
#
# The SHA must name a commit in the repo we install FROM, because that repo is the
# only one update.sh ever compares against. A local checkout's HEAD is not that
# commit: the checkout can be dirty, unpushed or behind, and the stamp then pairs
# $REPO_URL with a SHA that repo does not have — which makes every later
# comparison meaningless. So resolve the ref against the source repo itself,
# from a checkout and from a download alike.
resolve_template_sha() {
    # An exact SHA as the ref is already the answer. update.sh pins one when it
    # re-runs this installer.
    if [[ "$REPO_REF" =~ ^[0-9a-f]{7,40}$ ]]; then
        echo "${REPO_REF:0:7}"
        return 0
    fi

    # Ask the source repo. The `sha` media type returns the bare SHA as plain
    # text, so this needs neither gh nor jq.
    local sha=""
    case "$REPO_URL" in
        https://github.com/*)
            sha="$(curl -fsSL -m 5 -H 'Accept: application/vnd.github.sha' \
                "https://api.github.com/repos/${REPO_URL#https://github.com/}/commits/$REPO_REF" \
                2>/dev/null | cut -c1-7)"
            ;;
    esac
    if [[ -n "$sha" ]]; then
        echo "$sha"
        return 0
    fi

    # No answer from the network — the API is unreachable or rate-limited. A
    # checkout of the source repo still holds one: its remote-tracking ref, as of
    # the last fetch. That is the source repo's SHA, never the local HEAD. The
    # origin URL must match $REPO_URL, or the checkout tracks a different repo
    # and its refs say nothing about the one we install from.
    if [[ -z "$FETCHED_DIR" ]] \
       && [[ "$(normalize_repo_url "$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)")" \
             == "$(normalize_repo_url "$REPO_URL")" ]]; then
        git -C "$SCRIPT_DIR" rev-parse --short=7 "refs/remotes/origin/$REPO_REF" 2>/dev/null || true
    fi
}

# Prints each existing Docker object that would collide with the given name.
# Returns 0 if a collision was found, 1 if clean. Silent (and clean) when the
# Docker daemon is unreachable — name-format validation still applies.
list_conflicts() {
    local n="$1" found=0
    # The devcontainer's own objects carry the suffix. A compose project named
    # after the project alone is the repo's own stack, which is what the suffix
    # exists to leave alone, so this reports the suffixed name only. The two
    # patterns below keep the suffix optional, so the objects of an install from
    # before it are still reported.
    local dc="$n$DC_SUFFIX"

    docker_available || return 1

    # An existing compose project of the same name.
    if docker compose ls --all 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$dc"; then
        echo "  - docker compose project '$dc'"; found=1
    fi
    # The Claude login/config volume is deliberately NOT checked. Under the shared
    # choice its name is fixed (claude-shared) and every project mounts it; under
    # the project choice an existing <project>_claude volume holds the very login
    # this install goes on using. Either way it is expected, not a conflict. The compose file declares no per-project volumes of
    # its own (the Claude devcontainer feature does create one, named after the
    # compose project, but it is disposable and reappears on the next `up`).
    #
    # The image compose derives for the devcontainer service (<compose project>-devcontainer).
    local img
    while IFS= read -r img; do
        [[ -n "$img" ]] && { echo "  - docker image '$img'"; found=1; }
    done < <(docker images --format '{{.Repository}}' 2>/dev/null | grep -E "^${n}($DC_SUFFIX)?[-_]devcontainer$" || true)
    # Leftover containers using the project prefix.
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && { echo "  - docker container '$c'"; found=1; }
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${n}($DC_SUFFIX)?[-_]devcontainer" || true)

    [[ $found -eq 1 ]]
}
