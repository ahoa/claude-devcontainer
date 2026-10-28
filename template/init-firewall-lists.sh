# shellcheck shell=bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# init-firewall-lists.sh — the helpers of init-firewall.sh, which sources this
# file as root: the GitHub ranges, the host lists and their resolution into the
# allowed-domains ipset. The Dockerfile copies it to /usr/local/bin, root-owned.

add_cidrs() {
    local label="$1"
    # Reads CIDRs from stdin, validates, and adds to ipset
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            # Skipped, not fatal. The GitHub list carries IPv6 ranges too, and one
            # range this firewall cannot use must not turn the whole firewall off —
            # which is what the `exit 1` here used to do, on the open side of the
            # setup. A skipped range allows less, never more.
            echo "WARNING: $label supplied a range this firewall cannot use: $cidr" >&2
            continue
        fi
        echo "Adding $label range $cidr"
        # -exist makes a repeat a no-op, so a real refusal (a set that is full, an
        # address ipset rejects) is reported instead of swallowed.
        if ! ipset add allowed-domains "$cidr" -exist; then
            echo "WARNING: ipset refused the $label range $cidr — it is not allowed" >&2
        fi
    done
}

# The GitHub API allows 60 calls an hour per IP address without a token. Every
# project and every device behind the same NAT share that limit, and this
# script runs on each container start. A token raises the limit to 5000.
# The token is the optional file that git push in the container also reads,
# see Pushing from the container in the README. Without the file, the call is
# anonymous.
GH_TOKEN_FILE=/run/secrets/gh_token

# Fetches one GitHub API URL. On an error, it gives the HTTP status, and for a
# used-up rate limit also the reset time, instead of a generic failure.
fetch_github_json() {
    local url="$1" label="$2" tmp status token="" remaining reset
    tmp=$(mktemp -d)
    [[ -r "$GH_TOKEN_FILE" ]] && token=$(head -1 "$GH_TOKEN_FILE" | tr -d '[:space:]')
    # The token goes to curl on stdin. On the command line, ps shows it.
    status=$( { [[ -n "$token" ]] && printf 'Authorization: Bearer %s\n' "$token"; true; } \
        | curl -sS -m 10 -H @- -D "$tmp/headers" -o "$tmp/body" -w '%{http_code}' "$url" 2>"$tmp/err" ) || true
    if [[ "$status" == "200" ]]; then
        cat "$tmp/body"
        rm -rf "$tmp"
        return 0
    fi
    remaining=$(tr -d '\r' 2>/dev/null <"$tmp/headers" | awk -F': *' 'tolower($1) == "x-ratelimit-remaining" { v = $2 } END { print v }')
    reset=$(tr -d '\r' 2>/dev/null <"$tmp/headers" | awk -F': *' 'tolower($1) == "x-ratelimit-reset" { v = $2 } END { print v }')
    echo "ERROR: Failed to fetch $label from $url (HTTP ${status:-000})" >&2
    if [[ "$status" =~ ^(403|429)$ && "$remaining" == "0" && "$reset" =~ ^[0-9]+$ ]]; then
        echo "ERROR: The GitHub API rate limit for this IP address is used up. It resets at $(date -d "@$reset" '+%H:%M %Z')." >&2
        [[ -n "$token" ]] || echo "ERROR: Put a GitHub token in .devcontainer/.gh_token to get a higher limit. The README section Pushing from the container tells how." >&2
    elif [[ "$status" == "401" ]]; then
        echo "ERROR: The GitHub API refused the token in $GH_TOKEN_FILE." >&2
    elif [[ -s "$tmp/err" ]]; then
        echo "ERROR: $(tail -1 "$tmp/err")" >&2
    fi
    rm -rf "$tmp"
    exit 1
}

# The project's .devcontainer/, which docker-compose.yml mounts read-only. The
# installer substitutes the project name. The path is fixed here and not an
# argument, because the sudoers entry lets dev give this script any argument.
WORKSPACE_DC="/workspace/__PROJECT_NAME__/.devcontainer"

# Is WORKSPACE_DC a read-only mount? Only then can the agent not change the host
# lists in it. A container without that mount (an older compose file, a manual
# `docker run`) gets the copies baked into the image.
workspace_dc_read_only() {
    awk -v d="$WORKSPACE_DC" '$5 == d && $6 ~ /(^|,)ro(,|$)/ { f = 1 } END { exit !f }' \
        /proc/self/mountinfo 2>/dev/null
}

# The two host lists, one path per line: the template's baseline, which updates
# keep current, and the project's own additions, which they never touch.
#
# Each pair is the file in the read-only mount, then the copy in the image. The
# mount comes first: an edit on the host then applies with the next --refresh,
# without a rebuild. A mounted file must resolve to a path inside the mount. A
# symlink that leads out of it can lead into the writable project, where the
# agent could add a host.
conf_paths() {
    local pair mounted real read_only=0
    workspace_dc_read_only && read_only=1
    for pair in .template/domains-base.conf:/usr/local/bin/domains-base.conf \
                domains.conf:/usr/local/bin/domains.conf; do
        mounted="$WORKSPACE_DC/${pair%%:*}"
        real="$(realpath -e "$mounted" 2>/dev/null || true)"
        if [[ $read_only -eq 1 && -f "$real" && "$real" == "$WORKSPACE_DC"/* ]]; then
            echo "$real"
        else
            echo "${pair#*:}"
        fi
    done
}

# Resolve the hosts from the lists that conf_paths names and add their addresses
# to the ipset. `-exist` makes a repeat run a no-op.
allow_domain_ips() {
    local CONF domain ips ip
    for CONF in $(conf_paths); do
        [[ -f "$CONF" ]] || continue
        # `|| [[ -n "$domain" ]]` picks up a last line with no trailing newline, which
        # read reports as EOF and would otherwise drop silently.
        while IFS= read -r domain || [[ -n "$domain" ]]; do
            domain="${domain%%#*}"                  # drop comments, whole-line or trailing
            domain=$(echo "$domain" | xargs)        # then trim what is left
            [[ -z "$domain" ]] && continue
            # A bare IPv4 address or CIDR goes in as it is. It names a host that
            # has no DNS name, a Tailscale node for one, and dig would resolve nothing.
            if [[ "$domain" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
                ipset add allowed-domains "$domain" -exist
                continue
            fi
            ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
            if [[ -z "$ips" ]]; then
                echo "WARNING: $domain (from $(basename "$CONF")) did not resolve — not allowed"
                continue
            fi
            for ip in $ips; do
                ipset add allowed-domains "$ip" -exist
            done
        done < "$CONF"
    done
}

# The --refresh run: resolve the lists again and add the new addresses to the
# live ipset, flushing nothing.
refresh_domain_ips() {
    local before after
    if ! ipset list -t allowed-domains >/dev/null 2>&1; then
        echo "ERROR: ipset allowed-domains does not exist — run /usr/local/bin/init-firewall.sh without --refresh first" >&2
        exit 1
    fi
    before=$(ipset_entries)
    allow_domain_ips
    after=$(ipset_entries)
    echo "Firewall refresh complete: $((after - before)) new address(es) allowed"
}

ipset_entries() {
    ipset list -t allowed-domains | sed -n 's/^Number of entries: //p'
}
