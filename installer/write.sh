# shellcheck shell=bash
#
# The file writer of install.sh: the overwrite confirmation, the copy of the
# template with its placeholders substituted, the executable bits and ignores,
# the version stamp and the closing summary. Sourced by install.sh, shares its
# globals.

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

# A second install asks before it replaces the template files. --force skips
# the question, and so does update.sh, which passes it.
confirm_overwrite() {
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
}

# Copies the template into $DEST with the placeholders substituted. A user-owned
# file that exists is kept, and KEPT_FILES says which.
write_template_files() {
    mkdir -p "$DEST/$TEMPLATE_SUBDIR/base"
    KEPT_FILES=()
    for f in "${TEMPLATE_FILES[@]}"; do
        dest="$(dest_path "$f")"
        # A user-owned file that already exists is left untouched — this is what makes
        # a re-run an update rather than a clobber.
        if is_user_file "$f" && [[ -e "$dest" ]]; then
            KEPT_FILES+=("$f")
            continue
        fi
        # Each file is written beside its destination and then moved onto it, never
        # written over it. `cp` truncates the file that is already there, and that
        # corrupts whatever reads it. update.sh runs this installer, and update.sh is
        # one of the files the installer replaces. `mv` inside one directory is a
        # rename: a reader keeps the file it opened, and later readers get the new one.
        PENDING_WRITE="$dest.new"
        cp "$TEMPLATE_DIR/$f" "$PENDING_WRITE"
        # Substitute install-time placeholders. -i.bak works on both GNU and BSD sed.
        sed -i.bak \
            -e "s|__PROJECT_NAME__|$PROJECT_NAME|g" \
            -e "s|__COMPOSE_PROJECT__|$COMPOSE_PROJECT|g" \
            -e "s|__TMUX_WINDOWS__|$TMUX_WINDOWS|g" \
            -e "s|__TIMEZONE__|$TIMEZONE|g" \
            -e "s|__CLAUDE_VOLUME__|$CLAUDE_VOLUME|g" \
            -e "s|__DOCKER_FEATURE__|$DOCKER_FEATURE|g" \
            "$PENDING_WRITE"
        rm -f "$PENDING_WRITE.bak"
        mv -f "$PENDING_WRITE" "$dest"
        PENDING_WRITE=""
    done
}

# The executable bits, and the runtime files git must not see.
finish_template_files() {
    for f in "${EXECUTABLE_FILES[@]}"; do
        chmod +x "$DEST/$f"
    done

    # Keep runtime artifacts out of git: the build-input hash, the update-check cache
    # and the devcontainer CLI start.sh installs under .template/. Entry by entry, so
    # an install that predates one of them gains it — the file as a whole is left
    # alone, in case the project added lines of its own.
    touch "$DEST/.gitignore"
    for ignore in .build-hash .update-check node_modules/; do
        grep -qxF "$ignore" "$DEST/.gitignore" || echo "$ignore" >> "$DEST/.gitignore"
    done
}

# Record which template version this install came from, plus the answers needed to
# re-render it. update.sh reads this to know what to compare against and how to
# re-run the installer without asking again. Meant to be committed — it travels
# with the project, unlike the two runtime markers above.
write_stamp() {
    TEMPLATE_SHA="$(resolve_template_sha || true)"
    cat > "$DEST/.template-version" <<EOF
# Written by install.sh — do not edit by hand. Commit this file.
TEMPLATE_SHA=${TEMPLATE_SHA:-unknown}
TEMPLATE_REPO=$REPO_URL
TEMPLATE_REF=$TRACK_REF
PROJECT_NAME=$PROJECT_NAME
TMUX_WINDOWS=$TMUX_WINDOWS
TIMEZONE=$TIMEZONE
CLAUDE_LOGIN=$CLAUDE_LOGIN
DOCKER_SOCKET=$DOCKER_SOCKET
EOF
}

# What was installed, what was kept, and what an old layout left to do by hand.
print_summary() {
    cat <<EOF

✓ Installed Claude devcontainer into $DEST
    project name : $PROJECT_NAME
    compose proj : $COMPOSE_PROJECT (container $COMPOSE_PROJECT-devcontainer-1)
    tmux windows : $TMUX_WINDOWS
    timezone     : $TIMEZONE
    claude login : $CLAUDE_LOGIN (volume $CLAUDE_VOLUME)
    docker socket: $DOCKER_SOCKET
EOF

    if [[ ${#KEPT_FILES[@]} -gt 0 ]]; then
        printf '    kept as-is   : %s\n' "${KEPT_FILES[*]}"
    fi

    if [[ -n "$MIGRATED_OPEN_PORTS" ]]; then
        cat <<EOF

ℹ  Your old init-firewall.sh listed OPEN_PORTS=($MIGRATED_OPEN_PORTS). That array is
   gone: the firewall accepts the container's directly-connected subnets wholesale,
   so it never was what made those ports reachable. Publishing them is:

     # $DEST/docker-compose.override.yml
     services:
       devcontainer:
         ports:
$(for p in $MIGRATED_OPEN_PORTS; do printf '           - "%s:%s"\n' "$p" "$p"; done)
EOF
    fi

    if [[ $MIGRATED_FORWARDS -eq 1 ]]; then
        cat <<EOF

ℹ  Your old init-firewall.sh had PORT_FORWARDS entries. That mechanism is gone —
   it DNAT-ed localhost:PORT to a sibling service, which compose answers directly:
   reach the service by its name (db:5432) instead. If some config cannot be moved
   off localhost, give that service the devcontainer's network namespace with
   network_mode: "service:devcontainer" in docker-compose.override.yml.
EOF
    fi

    if [[ ${#BACKED_UP[@]} -gt 0 ]]; then
        cat <<EOF

⚠  This install replaced template-owned files that your project had customised.
   Verbatim copies are in $DEST:
$(printf '     %s\n' "${BACKED_UP[@]}")
   Nothing was thrown away, but moving the content across is manual — the old
   template had no marker saying which lines were yours, so it cannot be automated.
   Where each kind of change belongs now:

     toolchain (apt/curl installs)  → tools.sh
     iptables / ipset rules         → firewall.sh
     extra compose services         → docker-compose.override.yml
     outbound hosts                 → domains.conf

   ENV, COPY and other image-level lines fit none of those; keep them by forking
   this template and installing from the fork (see the README). Delete the
   .from-old files once you are done.
EOF
    fi

    cat <<EOF

The four files at the top of $DEST are yours to edit;
everything else there, including $TEMPLATE_SUBDIR/, is the template's and is
replaced on update.

Next:
  1. Add your project's toolchain to $DEST/tools.sh (Node/JDK/Python/…).
  2. Add any extra outbound hosts to $DEST/domains.conf, and any
     firewall rules the template cannot know about to $DEST/firewall.sh.
  3. Extra compose services go in $DEST/docker-compose.override.yml.
  4. Start it:   (cd "$TARGET_DIR" && ./.devcontainer/start.sh)
     Re-attach:  (cd "$TARGET_DIR" && ./.devcontainer/attach.sh)
EOF
}
