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
#     takes the running session with it. init-firewall.sh now reads the file in
#     the read-only .devcontainer/ mount itself, so the refresh below resolves
#     the hosts an edit added. The agent cannot change that mount.
#
# The refresh only adds. `init-firewall.sh --refresh` puts addresses into the
# live ipset and flushes nothing, so a tick cannot take this container's network
# down the way a failed full re-init could. The price is that a host REMOVED from
# domains.conf stays allowed until the next ./start.sh, which builds the rules
# from scratch.
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

tick() {
    local out new warnings line
    # Never let one bad tick end the watch: a resolver hiccup, or a firewall that
    # is not up yet, has to be survivable or the container spends the rest of the
    # session without a refresh.
    if out="$(sudo -n /usr/local/bin/init-firewall.sh --refresh 2>&1)"; then
        new="$(sed -n 's/^Firewall refresh complete: \([0-9]*\) new.*/\1/p' <<<"$out")"
        if [[ "${new:-0}" != "0" || $VERBOSE -eq 1 ]]; then
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
