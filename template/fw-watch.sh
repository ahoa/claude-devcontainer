#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. What a project needs is read from
# domains.conf, which is yours to edit.
#
# fw-watch.sh — keep the live firewall current while the container runs.
#
# Two things go stale between container starts:
#
#   * The addresses. The firewall resolves each host once, at start, and the
#     rules match those addresses only. A CDN host answers with other addresses
#     later, so a download can fail hours in although its host is allowed.
#   * domains.conf itself. It is COPYed into the image at build time, so an edit
#     on the host used to reach the container only through a rebuild — which
#     takes the running session with it. The repo is mounted, though, so the
#     edited file is right here: copy it over the baked one, and the refresh that
#     follows resolves the hosts it gained.
#
# Both steps only add. `init-firewall.sh --refresh` puts addresses into the live
# ipset and flushes nothing, so a tick cannot take this container's network down
# the way a failed full re-init could. The price is that a host REMOVED from
# domains.conf stays allowed until the next ./start.sh, which rebuilds the image
# (domains.conf is a build input) and applies the list from scratch. A tick that
# sees a removal says so.
#
# Modes:
#   --start   start the loop in the background, replacing one already running.
#             devcontainer.json's postStartCommand does this, once per start.
#   --once    one tick, then exit. This is what ./update-fw.sh runs from the host.
#   (none)    the loop, in the foreground.
#
# The background loop writes to /tmp/fw-watch.log and stays quiet unless
# something changed: `tail -f /tmp/fw-watch.log` inside the container.
set -euo pipefail

# Seconds between ticks. Long enough that ~30 DNS lookups per tick cost nothing,
# short enough that an edit to domains.conf applies while you are still looking
# at the terminal.
INTERVAL="${FW_WATCH_INTERVAL:-300}"
if [[ ! "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: FW_WATCH_INTERVAL must be a positive number of seconds (got '$INTERVAL')." >&2
    exit 1
fi

LOG=/tmp/fw-watch.log
PIDFILE=/tmp/fw-watch.pid

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVCONTAINER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Each pair is "the file in the mounted repo" and "the copy the image was built
# with", in the order init-firewall.sh reads them: the template's baseline and
# the project's own additions.
CONFS=(
    "$SCRIPT_DIR/domains-base.conf:/usr/local/bin/domains-base.conf"
    "$DEVCONTAINER_DIR/domains.conf:/usr/local/bin/domains.conf"
)

# A one-off run reports what it did; the loop only speaks when something changed,
# because its log is read when something failed, not to prove it is alive.
VERBOSE=0
# The warnings the previous tick printed. A host that has stopped resolving warns
# on every tick for as long as it stays broken, which would fill the log with one
# repeated line; this reports each change of the set once.
LAST_WARNINGS=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Is that pid this script, still running? The pid alone is not enough — the file
# outlives the process that wrote it, and the container reuses pids.
is_watcher() {
    local cmdline
    # The braces matter. A redirect that cannot open its file reports that
    # itself, before the command runs, so `tr ... < /proc/x 2>/dev/null` still
    # prints "No such file or directory" — and the file does disappear here, in
    # the moment between the check and the read, because this is asked about a
    # process that is on its way out.
    cmdline="$( { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null || true)"
    [[ "$cmdline" == *fw-watch.sh* ]]
}

# The hosts a list names, comments and blank lines removed, for comparing two
# versions of the same file.
conf_hosts() {
    sed 's/#.*//' "$1" | awk '{$1=$1; print}' | grep -v '^$' | sort -u || true
}

# Copy a changed list over the baked one. Reports whether it changed anything, so
# the caller knows to speak up about a tick it would otherwise keep quiet.
sync_conf() {
    local src="$1" baked="$2" name removed=""
    name="$(basename "$src")"
    [[ -f "$src" ]] || return 1
    # A missing baked copy means the image predates this list; copying it in is
    # still the right move.
    if [[ -f "$baked" ]] && cmp -s "$src" "$baked"; then
        return 1
    fi
    if [[ -f "$baked" ]]; then
        removed="$(comm -23 <(conf_hosts "$baked") <(conf_hosts "$src") | tr '\n' ' ')"
    fi
    if ! sudo -n cp "$src" "$baked" 2>/dev/null; then
        log "WARNING: $name changed but could not be copied to $baked — its new hosts are not allowed"
        return 1
    fi
    log "$name changed — applying it"
    if [[ -n "${removed// /}" ]]; then
        log "  no longer listed: ${removed% } — still allowed until ./start.sh rebuilds"
    fi
    return 0
}

tick() {
    local changed=0 pair out new warnings line
    for pair in "${CONFS[@]}"; do
        sync_conf "${pair%%:*}" "${pair#*:}" && changed=1
    done

    # Never let one bad tick end the watch: a resolver hiccup, or a firewall that
    # is not up yet, has to be survivable or the container spends the rest of the
    # session without a refresh.
    if out="$(sudo -n /usr/local/bin/init-firewall.sh --refresh 2>&1)"; then
        new="$(sed -n 's/^Firewall refresh complete: \([0-9]*\) new.*/\1/p' <<<"$out")"
        if [[ "${new:-0}" != "0" || $changed -eq 1 || $VERBOSE -eq 1 ]]; then
            log "refresh: ${new:-0} new address(es) allowed"
        fi
        # A host that stopped resolving is worth seeing when it starts, and not
        # once every tick from then on.
        warnings="$(grep '^WARNING:' <<<"$out" || true)"
        if [[ -n "$warnings" && ( "$warnings" != "$LAST_WARNINGS" || $VERBOSE -eq 1 ) ]]; then
            while IFS= read -r line; do log "  $line"; done <<<"$warnings"
        fi
        LAST_WARNINGS="$warnings"
        return 0
    fi
    log "ERROR: refresh failed"
    sed 's/^/  /' <<<"$out"
    return 1
}

case "${1:-}" in
    --start)
        # Launch the loop and return at once: the devcontainer CLI waits for
        # postStartCommand to finish. A loop from an earlier start goes first —
        # `devcontainer up` on a container that is already running runs
        # postStartCommand again, and an updated template must not leave the old
        # script running beside the new one.
        OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ "$OLD" =~ ^[0-9]+$ ]] && is_watcher "$OLD"; then
            # TERM first, but do not trust it to be quick: the loop spends almost
            # all of its life inside `sleep`, and bash runs no handler until that
            # returns — up to a whole interval away. KILL ends it now, and there
            # is nothing to clean up, because a tick only ever adds to the ipset.
            kill "$OLD" 2>/dev/null || true
            for _ in 1 2 3 4 5; do
                is_watcher "$OLD" || break
                sleep 0.2
            done
            is_watcher "$OLD" && kill -9 "$OLD" 2>/dev/null || true
        fi
        # setsid so the loop outlives the shell the CLI runs this in; nohup alone
        # leaves it in that shell's process group. </dev/null so nothing waits on
        # a pipe the CLI is reading.
        LAUNCH=(nohup)
        command -v setsid >/dev/null 2>&1 && LAUNCH=(setsid nohup)
        "${LAUNCH[@]}" "$0" >>"$LOG" 2>&1 </dev/null &
        echo "Firewall watcher: every ${INTERVAL}s, log in $LOG"
        exit 0
        ;;
    --once)
        VERBOSE=1
        tick || exit 1
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Usage: $0 [--start | --once]" >&2
        exit 1
        ;;
esac

# The loop records its own pid, so --start kills the loop and not the shell that
# happened to launch it. Nothing removes this file: a pid that is gone, or that
# the container reused for something else, is rejected by is_watcher.
echo $$ > "$PIDFILE"

log "watching domains.conf and the resolved addresses every ${INTERVAL}s"
while true; do
    tick || true
    sleep "$INTERVAL"
done
