#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. What a project needs is read from
# domains.conf and firewall.sh, both of which are yours to edit.
#
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# The helpers: the GitHub ranges, the host lists and their resolution. A file of
# its own, but root-owned in /usr/local/bin like this one, because dev may sudo
# this script and the helpers then run as root.
# shellcheck source=template/init-firewall-lists.sh
source /usr/local/bin/init-firewall-lists.sh

# --- Main script ---

# --refresh: resolve the host lists again and add every new address to the live
# ipset. It flushes nothing, so the firewall stays up throughout.
#
# The full run resolves each host once, at container start, and the rules then
# match those addresses only. A CDN host (the Playwright download is one) answers
# with different edge addresses every few seconds, so a download hours later can
# hit an address the set never saw. The sudoers entry covers this flag too, so
# from the dev shell:
#     sudo /usr/local/bin/init-firewall.sh --refresh
# From the host, ./.devcontainer/update-fw.sh runs the same command.
REFRESH=0
case "${1:-}" in
    --refresh) REFRESH=1 ;;
    "")        ;;
    *)         echo "Usage: $0 [--refresh]" >&2; exit 1 ;;
esac

# A full run flushes every rule and opens the policies while it builds them
# again, so traffic can leave for some seconds. dev may sudo this script, and
# with --docker off has no other way to root. So a full run in a container whose
# firewall is up refreshes instead: only container start, or a run after a
# failed one, rebuilds the rules. The catch-all REJECT is the last rule a
# successful full run adds, and fail_closed removes it.
if [[ $REFRESH -eq 0 ]] && iptables -C OUTPUT -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null; then
    echo "The firewall is already up in this container. Refreshing the host lists instead of a full run."
    REFRESH=1
fi

if [[ $REFRESH -eq 1 ]]; then
    refresh_domain_ips
    exit 0
fi

echo "=== Initializing container firewall ==="
workspace_dc_read_only \
    || echo "WARNING: $WORKSPACE_DC is not a read-only mount — using the host lists baked into the image"

# Flush our own rules and ipset. Only the filter table: every rule this script adds
# lives there, so nat and mangle are none of its business.
#
# It used to flush nat too, saving and restoring just the 127.0.0.11 DNS rules. That
# threw away the rest of the runtime's plumbing — including the DNAT that makes the
# host reachable at host.docker.internal — and left the container unable to talk to
# anything running on the host, which is where the application under development
# runs. Leaving nat alone fixes that and needs no save/restore dance.
iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

# Flushing rules does NOT reset the chain policies, so a re-run inside a container
# that is already firewalled would sit on DROP policies with every ACCEPT rule just
# deleted — no egress at all. The GitHub fetch below would then fail and this
# script would exit half-applied, leaving the container with no working network
# until it is recreated. Reset the policies explicitly; they go back to DROP at the
# end, once the allow rules are in place.
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

# From this point to the DROP policies at the end of the script, the chains are
# open. Every failure in between used to leave them that way: `set -e` ends the
# script, the ACCEPT policies stay, and the container runs with no firewall at all.
# A GitHub API request that timed out was enough. That is the wrong direction to
# fail in, so close the network instead.
#
# The rules go too, not only the policies. A half-applied set of allow rules is
# not a state worth keeping, and a container with no route out is easier to
# recognize than one that is quietly too permissive. Recovery needs no network:
# fix the cause, then run the command this prints.
fail_closed() {
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    echo "ERROR: firewall setup failed (exit $rc) — closing this container's network" >&2
    iptables -P INPUT DROP   2>/dev/null || true
    iptables -P OUTPUT DROP  2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    echo "The container cannot reach anything now. Fix the cause, then run:" >&2
    echo "  sudo /usr/local/bin/init-firewall.sh" >&2
}
trap fail_closed EXIT

# IPv6, closed as a whole.
#
# Every allow rule in this script is IPv4: a host is resolved to its A records,
# and the ipset holds IPv4 networks. So an IPv6 route out of the container matches
# no allowlist and walks around all of it — and nothing here touched ip6tables, on
# any runtime that gives the container IPv6.
#
# Closed here, at the same point as the IPv4 flush, and the catch-all REJECT is
# appended at the end of the script next to the IPv4 one. A rule that firewall.sh
# adds for IPv6 thus survives this flush and still lands before that REJECT, which
# is how the IPv4 rules already work.
#
# The policies go first, so a partial application still leaves IPv6 closed.
IPV6_FILTERED=0
ip6_close() {
    ip6tables -P INPUT DROP \
        && ip6tables -P OUTPUT DROP \
        && ip6tables -P FORWARD DROP \
        && ip6tables -F \
        && ip6tables -X \
        && ip6tables -A INPUT  -i lo -j ACCEPT \
        && ip6tables -A OUTPUT -o lo -j ACCEPT
}
if ! command -v ip6tables >/dev/null 2>&1; then
    echo "Note: this image has no ip6tables — IPv6 rules skipped"
elif ip6_close 2>/dev/null; then
    IPV6_FILTERED=1
    echo "IPv6 closed: DROP policies, loopback only"
else
    echo "WARNING: could not apply the IPv6 rules. If this container has IPv6, egress over it is unfiltered." >&2
fi

# Localhost first. The container runtime answers DNS on 127.0.0.11, and every
# rule below needs name resolution.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS, to this container's own resolvers only.
#
# An unrestricted `--dport 53` rule used to stand here, and it reached any
# nameserver on the internet. That is a way out of the sandbox that needs no
# allowed host and no root: a lookup of secret.attacker.example carries the
# payload in the name itself, and the answer carries a reply back. Restricting the
# destination closes the channel and costs nothing, because a container resolves
# through the resolvers it was given.
#
# The addresses are read from /etc/resolv.conf rather than guessed: Docker
# publishes 127.0.0.11, and Docker Desktop and OrbStack publish an address on the
# host. tcp/53 goes with it, for an answer too large for one UDP packet — which
# the old rule pair did not cover at all.
DNS_SERVERS=$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf 2>/dev/null \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u)
if [ -z "$DNS_SERVERS" ]; then
    echo "ERROR: /etc/resolv.conf names no IPv4 resolver — cannot allow DNS"
    exit 1
fi
for ns in $DNS_SERVERS; do
    echo "Allowing DNS resolver: $ns"
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    iptables -A INPUT -p udp -s "$ns" --sport 53 -j ACCEPT
done

# There is deliberately no rule for tcp/22.
#
# One used to stand here, and it accepted SSH to every address there is. The whole
# host list was one step away from useless: `curl https://any.host:22/` went
# straight out, and an SSH tunnel carried anything else. Git over SSH still works
# for a host that is allowed, because the allowed-domains rule at the end of this
# script matches every port on those addresses.

# Inbound ports need no rules of their own. The application under development runs
# on the host, not in here, and the directly-connected subnets allowed below cover
# everything that legitimately reaches this container. Exposing a port from the
# container to a host browser is a `ports:` entry in docker-compose.override.yml;
# the firewall does not stand in the way of it.

# Create ipset with CIDR support (maxelem increased for CloudFront ranges)
ipset create allowed-domains hash:net maxelem 65536

# Fetch and add GitHub IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(fetch_github_json "https://api.github.com/meta" "GitHub IP ranges")

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q | add_cidrs "GitHub"

# Resolve the configured hosts (domains-base.conf + domains.conf). Once, at start:
# a host whose addresses rotate later needs `--refresh`, see the top of the file.
allow_domain_ips

# Allow every subnet this container is directly attached to. That covers the path
# to the host — where the application under development normally runs — and any
# sibling compose containers.
#
# Read from the routing table rather than guessed. The previous version did both:
# it turned the default gateway into a /24 (right only when the gateway's prefix
# happens to be /24) and grepped the routes for 172.x (matching nothing at all on
# runtimes that use another range, e.g. OrbStack's 192.168.x). Where it worked, it
# worked by coincidence.
LINK_NETS=$(ip -4 route show scope link | awk '$1 ~ /\// && $1 !~ /^169\.254\./ {print $1}' | sort -u)
if [ -z "$LINK_NETS" ]; then
    echo "ERROR: no directly-connected IPv4 subnets found — cannot reach the host"
    exit 1
fi
for net in $LINK_NETS; do
    echo "Allowing directly-connected network: $net"
    iptables -A INPUT -s "$net" -j ACCEPT
    iptables -A OUTPUT -d "$net" -j ACCEPT
done

# The host itself, under the names the runtime publishes for it. This is the whole
# point of the sandbox as used here: the application under development runs on the
# host, and the container has to reach it.
#
# A directly-connected subnet is not enough. OrbStack answers host.docker.internal
# with an address outside every route (0.250.250.254), so without an explicit rule
# the host is unreachable — as it was until this rule existed. Nothing is assumed
# about the address: whatever the names resolve to is what gets allowed, and a name
# that does not resolve is skipped.
HOST_IPS=$(for host_alias in host.docker.internal gateway.docker.internal host.internal; do
    dig +short "$host_alias" 2>/dev/null | grep -E '^[0-9]+\.' || true
done | sort -u)
for ip in $HOST_IPS; do
    echo "Allowing host address: $ip"
    iptables -A OUTPUT -d "$ip" -j ACCEPT
    iptables -A INPUT -s "$ip" -j ACCEPT
done

# Project-specific rules (user-owned firewall.sh). Sourced here on purpose:
# every allow rule above is in place, the policies are still ACCEPT, and the
# catch-all REJECT below has not been appended yet — so a rule added there lands
# where it actually takes effect.
EXTRA_CONF="/usr/local/bin/firewall.sh"
if [[ -f "$EXTRA_CONF" ]]; then
    echo "Applying project rules from $(basename "$EXTRA_CONF")"
    # shellcheck source=/dev/null
    source "$EXTRA_CONF"
fi

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# The same catch-all for IPv6. REJECT and not DROP, so a client that tries IPv6
# first fails at once and falls back to IPv4 instead of waiting for a timeout.
if [[ $IPV6_FILTERED -eq 1 ]]; then
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null \
        || echo "WARNING: no IPv6 reject rule — IPv6 egress is dropped, not rejected" >&2
fi

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 -m 10 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access. Any HTTP answer proves that the firewall lets the
# traffic through, so curl has no -f. /rate_limit does not count against the
# rate limit, but /zen did, on each container start.
if ! curl --connect-timeout 5 -m 10 https://api.github.com/rate_limit >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# IPv6, which no allow rule covers. A success here means the whole filter can be
# walked around over IPv6. A container without IPv6 reports the same failure as a
# closed one, and for this sandbox both mean the same thing: no way out over IPv6.
if curl -6 --connect-timeout 5 -m 10 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - reached https://example.com over IPv6"
    exit 1
else
    echo "Firewall verification passed - no IPv6 egress"
fi
