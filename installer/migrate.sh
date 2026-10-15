# shellcheck shell=bash
#
# Migrations from earlier template layouts, for install.sh: the pre-split
# config files, the machinery left at the top of .devcontainer/, the
# per-project Claude login volume and the session bucket. Each one is a no-op
# on a fresh install. Sourced by install.sh, shares its globals.

# Lift a pre-split install's customizations into the user-owned files, before the
# template files that used to hold them are overwritten. Older templates kept the
# project's ports inside init-firewall.sh and its toolchain inside the Dockerfile;
# both are template-owned now, so this is the last moment either can be recovered
# automatically. Recognised by the absence of .template-version, which every
# post-split install writes.
migrate_pre_split_config() {
    [[ -d "$DEST" && ! -f "$DEST/.template-version" ]] || return 0

    # Keep verbatim copies of every template-owned file about to be replaced, before
    # anything here touches them. Unconditional on purpose: the older templates had
    # no marker delimiting "your part", customizations sit anywhere in these files,
    # and a project may have rewritten init-firewall.sh outright — several have.
    # Guessing which lines are the user's is not possible, so keep the whole file.
    local f
    for f in Dockerfile docker-compose.yml init-firewall.sh; do
        [[ -f "$DEST/$f" && ! -f "$DEST/$f.from-old" ]] || continue
        cp "$DEST/$f" "$DEST/$f.from-old"
        BACKED_UP+=("$f.from-old")
    done

    # The host list keeps its format and only changes name.
    if [[ ! -f "$DEST/domains.conf" && -f "$DEST/allowed-domains.conf" ]]; then
        mv "$DEST/allowed-domains.conf" "$DEST/domains.conf"
        echo "→ Renamed allowed-domains.conf to domains.conf (your entries are untouched)"
    fi

    # Neither of the old port arrays is carried over: nothing reads them any more.
    # OPEN_PORTS never was what made a port reachable (the firewall accepts the
    # directly-connected subnets wholesale), and PORT_FORWARDS existed to fake
    # localhost:PORT for a sibling service — which compose already answers with a
    # service name. Both are reported rather than copied, so a project that used them
    # is told what replaces them instead of keeping config nothing honours.
    local old_ports
    old_ports="$(sed -n 's/^OPEN_PORTS=(\(.*\))/\1/p' "$DEST/init-firewall.sh.from-old" 2>/dev/null | head -1)"
    [[ -n "${old_ports// /}" ]] && MIGRATED_OPEN_PORTS="$old_ports"
    if awk '/^PORT_FORWARDS=\(/,/\)/' "$DEST/init-firewall.sh.from-old" 2>/dev/null | grep -q '"'; then
        MIGRATED_FORWARDS=1
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

# Link the sessions of a pre-per-project install into this project's bucket.
# Claude names the directory that holds its sessions after the working directory,
# so the move from /workspace to /workspace/<name> left every session written
# before it in a bucket nothing lists any more. This links them into the new
# bucket, once per volume and project. The old bucket also holds the sessions of
# the other projects that shared /workspace, and those come too — one bucket is
# what each project already listed, so nothing gets worse.
#
# The transcripts are hardlinked, not copied. Both buckets sit in one volume, so
# the 350 MB a grown bucket holds costs nothing a second time. The memory/
# directory is copied instead: two projects that share one inode would read each
# other's edits.
migrate_claude_sessions() {
    docker_available || return 0
    docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$CLAUDE_VOLUME" || return 0

    # Claude replaces every character that is not a letter or a digit with '-', so
    # a project name that holds '_' has two candidate bucket names. The helper below
    # takes the sanitized name and prefers a bucket that already exists.
    local bucket script out status
    bucket="$(printf %s "/workspace/$PROJECT_NAME" | sed 's/[^a-zA-Z0-9]/-/g')"

    # The heredoc body has to sit inside the command substitution, so the script
    # goes into a variable here and reaches the helper container over its stdin.
    script="$(cat <<'MIGRATE'
set -eu
bucket="$1"
if [ "$2" != "$1" ] && [ -d "/v/projects/$2" ] && [ ! -d "/v/projects/$1" ]; then
  bucket="$2"
fi
old=/v/projects/-workspace
new="/v/projects/$bucket"
marker="/v/projects/.migrated-to-$bucket"

if [ ! -d "$old" ]; then exit 3; fi
if [ -e "$marker" ]; then exit 4; fi

owner="$(stat -c '%u:%g' "$old")"
mode="$(stat -c '%a' "$old")"
mkdir -p "$new"
chown "$owner" "$new"
chmod "$mode" "$new"

linked=0
for entry in "$old"/*; do
  if [ ! -e "$entry" ]; then continue; fi
  name="${entry##*/}"
  if [ "$name" = memory ]; then continue; fi
  if [ -e "$new/$name" ]; then continue; fi
  if [ -d "$entry" ]; then
    cp -al "$entry" "$new/$name" 2>/dev/null || cp -a "$entry" "$new/$name"
  else
    ln "$entry" "$new/$name" 2>/dev/null || cp -a "$entry" "$new/$name"
  fi
  linked=$((linked + 1))
done

# Copied, never linked — see the comment on the calling function.
if [ -d "$old/memory" ] && [ -z "$(ls -A "$new/memory" 2>/dev/null)" ]; then
  mkdir -p "$new/memory"
  chown "$owner" "$new/memory"
  cp -a "$old"/memory/. "$new"/memory/
fi

: > "$marker"
chown "$owner" "$marker"
echo "$linked $bucket"
MIGRATE
)"

    set +e
    out="$(printf '%s\n' "$script" \
        | docker run --rm -i -v "$CLAUDE_VOLUME":/v alpine sh -s -- \
              "$bucket" "-workspace-$PROJECT_NAME" 2>&1)"
    status=$?
    set -e

    case $status in
        0) echo "→ Linked ${out%% *} old Claude session entries from the /workspace bucket into ${out##* }" ;;
        3|4) : ;;  # nothing there to migrate, or an earlier run did it
        *) echo "WARNING: could not link the old Claude sessions into $bucket — ${out:-no output}" >&2 ;;
    esac
}
