# shellcheck shell=bash
#
# The questions of install.sh, and the prompt helpers they share. Sourced by
# install.sh, so every variable here is a global of that script. Each ask_*
# function takes the answer an argument gave, else prompts with the answer of
# an existing install as the default, then validates. A bad argument is fatal,
# a bad typed answer asks again.

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
    # The name becomes a symlink target in the image (/usr/share/zoneinfo/$TZ),
    # so it must not walk out of that directory.
    [[ "$1" != *..* ]] || return 1
    if [[ -d /usr/share/zoneinfo ]]; then
        [[ -f "/usr/share/zoneinfo/$1" ]] || return 1
    fi
}

# ── Resolve the project name (validate + conflict-check, re-prompt as needed) ─
ask_project_name() {
    while :; do
        if [[ -z "$PROJECT_NAME" ]]; then
            if [[ -n "$EXISTING_NAME" ]]; then
                prompt_user PROJECT_NAME "Project name [$EXISTING_NAME]: " || true
                PROJECT_NAME="${PROJECT_NAME:-$EXISTING_NAME}"
            elif ! prompt_user PROJECT_NAME "Project name (Docker image / compose project / volumes): "; then
                echo "ERROR: no project name given and no terminal to prompt on. Use --name NAME." >&2
                exit 1
            fi
        fi

        if ! validate_name "$PROJECT_NAME"; then
            echo "Invalid name '$PROJECT_NAME'. Use lowercase letters, digits, '-' and '_'; must start with a letter or digit." >&2
            if [[ $NAME_FROM_ARG -eq 1 ]] || ! have_tty; then exit 1; fi
            PROJECT_NAME=""; continue
        fi

        # Re-installing over the same project: the compose project, image and container
        # it finds are this project's own, so there is nothing to conflict with.
        if [[ "$PROJECT_NAME" == "$EXISTING_NAME" ]]; then
            break
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

    # The name compose gives the devcontainer's project, and with it the container
    # name (<compose project>-devcontainer-1) and the image name. See DC_SUFFIX above.
    COMPOSE_PROJECT="${PROJECT_NAME}${DC_SUFFIX}"
}

# ── Number of tmux windows ────────────────────────────────────────────────────
ask_windows() {
    if [[ -z "$TMUX_WINDOWS" ]]; then
        prompt_user TMUX_WINDOWS "How many tmux windows (each runs its own Claude)? [${EXISTING_WINDOWS:-1}]: " || true
        TMUX_WINDOWS="${TMUX_WINDOWS:-${EXISTING_WINDOWS:-1}}"
    fi
    if [[ ! "$TMUX_WINDOWS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: --windows must be a positive integer (got '$TMUX_WINDOWS')." >&2
        exit 1
    fi
}

# ── Container timezone ────────────────────────────────────────────────────────
# Without this the container runs UTC. Re-prompts on a bad zone when there is a
# terminal; a bad --timezone is fatal.
ask_timezone() {
    while :; do
        if [[ -z "$TIMEZONE" ]]; then
            prompt_user TIMEZONE "Container timezone (IANA name) [${EXISTING_TIMEZONE:-$DEFAULT_TIMEZONE}]: " || true
            TIMEZONE="${TIMEZONE:-${EXISTING_TIMEZONE:-$DEFAULT_TIMEZONE}}"
        fi

        if validate_timezone "$TIMEZONE"; then break; fi

        echo "Unknown or malformed timezone '$TIMEZONE'. Use an IANA name, e.g. Europe/Tallinn or UTC." >&2
        if [[ $TZ_FROM_ARG -eq 1 ]] || ! have_tty; then exit 1; fi
        TIMEZONE=""
    done
}

# ── Where Claude's login lives ────────────────────────────────────────────────
# shared  — one claude-shared volume, mounted by every project installed from this
#           template, so a single /login covers all of them. It also means the
#           container of any one project reads the token that all the others use.
# project — a volume of this project's own. A second /login to do, and a repo you
#           do not trust cannot read the credentials of the rest.
ask_login() {
    while :; do
        if [[ -z "$CLAUDE_LOGIN" ]]; then
            prompt_user CLAUDE_LOGIN "Claude login shared with your other projects, or this project only? [shared/project, ${EXISTING_LOGIN:-shared}]: " || true
            CLAUDE_LOGIN="${CLAUDE_LOGIN:-${EXISTING_LOGIN:-shared}}"
        fi

        [[ "$CLAUDE_LOGIN" == "shared" || "$CLAUDE_LOGIN" == "project" ]] && break

        echo "Answer 'shared' or 'project' (got '$CLAUDE_LOGIN')." >&2
        if [[ $LOGIN_FROM_ARG -eq 1 ]] || ! have_tty; then exit 1; fi
        CLAUDE_LOGIN=""
    done
    # The project-scoped name is the one the pre-shared-login template used, so a
    # project that still has that volume keeps its login with nothing to migrate.
    if [[ "$CLAUDE_LOGIN" == "shared" ]]; then
        CLAUDE_VOLUME="claude-shared"
    else
        CLAUDE_VOLUME="${PROJECT_NAME}_claude"
    fi
}

# ── The host Docker socket ────────────────────────────────────────────────────
# on  — the container drives the host Docker daemon, which tests that start their
#       own containers need. It is also control of the host: a container that can
#       reach that socket can start a privileged one, so this is the loosest part
#       of the sandbox by a wide margin. The docker-outside-of-docker feature
#       mounts the socket and proxies it to dev. Nothing else may mount it: a
#       second mount on /var/run/docker.sock stops the feature's proxy, and dev
#       is left with the host's root-owned socket (see docker-compose.yml).
# off — no docker-outside-of-docker feature. Nothing in the container can reach
#       Docker, and the Dockerfile removes dev's passwordless sudo. The default.
ask_docker() {
    while :; do
        if [[ -z "$DOCKER_SOCKET" ]]; then
            prompt_user DOCKER_SOCKET "Mount the host Docker socket? It gives the container control of the host. [on/off, ${EXISTING_DOCKER:-off}]: " || true
            DOCKER_SOCKET="${DOCKER_SOCKET:-${EXISTING_DOCKER:-off}}"
        fi

        [[ "$DOCKER_SOCKET" == "on" || "$DOCKER_SOCKET" == "off" ]] && break

        echo "Answer 'on' or 'off' (got '$DOCKER_SOCKET')." >&2
        if [[ $DOCKER_FROM_ARG -eq 1 ]] || ! have_tty; then exit 1; fi
        DOCKER_SOCKET=""
    done
    # The placeholder sits on a line of its own in the template, so the comment form
    # is what an "off" install reads in .devcontainer/.template/.
    if [[ "$DOCKER_SOCKET" == "on" ]]; then
        DOCKER_FEATURE='"ghcr.io/devcontainers/features/docker-outside-of-docker:1": { "moby": false }'
    else
        DOCKER_FEATURE='// not installed — this project was installed with --docker off'
    fi
    # The Dockerfile line that keeps or removes dev's passwordless sudo, see the
    # comment above the placeholder there.
    if [[ "$DOCKER_SOCKET" == "on" ]]; then
        SUDO_CLEANUP='# --docker on: dev keeps passwordless sudo.'
    else
        SUDO_CLEANUP='RUN rm -f /etc/sudoers.d/dev; ! grep -rqs "NOPASSWD: *ALL" /etc/sudoers /etc/sudoers.d'
    fi
}
